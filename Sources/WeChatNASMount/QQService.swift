import Foundation
import CryptoKit

struct QQMigration: Codable, Sendable {
    var source: String
    var backup: String
    var destination: String
}

enum QQService {
    static var fm: FileManager { FileManager.default }
    static let journal = AppPaths.support.appendingPathComponent("qq-migrations.json")
    static let accountRoot = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.tencent.qq/Data/Library/Application Support/QQ")

    static func migrations(at url: URL = journal) throws -> [QQMigration] {
        guard fm.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([QQMigration].self, from: Data(contentsOf: url))
    }
    static func write(_ entries: [QQMigration], at url: URL = journal) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
    static func requireQQClosed() throws {
        let result = try CommandRunner.run("/usr/bin/pgrep", ["-x", "QQ"])
        guard result.0 == 1 else { throw failure("请先完全退出 QQ，再迁移或恢复图片缓存。") }
    }
    static func validateJournal(_ entries: [QQMigration]) throws {
        for entry in entries {
            let source = URL(fileURLWithPath: entry.source)
            let account = source.deletingLastPathComponent().deletingLastPathComponent()
            guard account.deletingLastPathComponent().path == accountRoot.path,
                  account.lastPathComponent.range(of: "^nt_qq_[a-fA-F0-9]+$", options: .regularExpression) != nil,
                  source.path == account.appendingPathComponent("nt_data/Pic").path,
                  entry.backup.hasPrefix(entry.source + ".nas-backup-"),
                  URL(fileURLWithPath: entry.backup).deletingLastPathComponent().path == source.deletingLastPathComponent().path else {
                throw failure("QQ 迁移记录无效，已停止操作。")
            }
        }
    }
    static func assertConfigurationUnchanged(_ old: Configuration, _ new: Configuration) throws {
        if try !migrations().isEmpty {
            guard old.server == new.server, old.fallbackServer == new.fallbackServer,
                  old.share == new.share, old.username == new.username,
                  old.remoteDirectory == new.remoteDirectory, old.mountPoint == new.mountPoint else {
                throw failure("QQ 已有迁移记录。请先恢复本地图片，再修改 QQ 的 NAS 位置。")
            }
            guard new.enabled else { throw failure("请先恢复本地图片，再关闭 QQ 自动连接。") }
        }
    }
    static func protectMountPoint(_ config: Configuration, forFeishu: Bool = false) throws {
        if forFeishu { try FeishuService.validate(config) } else { try config.validate(forQQ: true) }
        guard !MountService.isMounted(config) else { return }
        let listing = try CommandRunner.run("/sbin/mount", []).1
        guard !listing.contains(" on \(config.mountPoint) (") else { throw failure("图片缓存挂载点已被其他共享占用。") }
        let url = URL(fileURLWithPath: config.mountPoint)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        guard parent.path == url.deletingLastPathComponent().path,
              (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw failure("图片缓存挂载点或其父目录不能是符号链接。")
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        guard try fm.contentsOfDirectory(atPath: url.path).isEmpty else {
            throw failure("图片缓存挂载点存在本地文件，已停止挂载以避免遮蔽数据。")
        }
        // When unmounted, QQ cannot create its remote directory tree on the local disk.
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
    }
    static func mount(_ config: Configuration, forFeishu: Bool = false) throws {
        if forFeishu { try FeishuService.validate(config) } else { try config.validate(forQQ: true) }
        if MountService.isMounted(config) { return }
        try protectMountPoint(config, forFeishu: forFeishu)
        var errors: [String] = []
        for host in [config.server, config.fallbackServer].filter({ !$0.isEmpty }) {
            let result = try CommandRunner.run("/sbin/mount_smbfs", ["-N", "-s", "-o", "nobrowse,noowners,soft",
                "//\(config.username)@\(host)/\(config.share)", config.mountPoint])
            if result.0 == 0 && MountService.isMounted(config) { return }
            errors.append("\(host)：\(result.1)")
        }
        throw failure(errors.joined(separator: "\n"))
    }
    static func ensureRemotePath(_ url: URL, mountPoint: String, create: Bool) throws {
        let mount = URL(fileURLWithPath: mountPoint).standardizedFileURL
        guard url.standardizedFileURL.path.hasPrefix(mount.path + "/") || url.standardizedFileURL == mount else {
            throw failure("远端路径越过了 NAS 挂载点。")
        }
        var current = mount
        for component in url.path.dropFirst(mount.path.count).split(separator: "/") {
            current.appendPathComponent(String(component))
            if (try? fm.destinationOfSymbolicLink(atPath: current.path)) != nil { throw failure("NAS 目标路径不能包含符号链接。") }
            if create && !fm.fileExists(atPath: current.path) { try fm.createDirectory(at: current, withIntermediateDirectories: false) }
        }
    }
    static func probe(_ config: Configuration) throws -> Int {
        guard MountService.isMounted(config) else { throw failure("QQ NAS 未挂载。") }
        try ensureRemotePath(config.remoteRoot, mountPoint: config.mountPoint, create: false)
        _ = try fm.contentsOfDirectory(atPath: config.mountPoint)
        let entries = try migrations(); try validateJournal(entries)
        for entry in entries {
            guard entry.destination.hasPrefix(config.remoteRoot.path + "/"),
                  try fm.destinationOfSymbolicLink(atPath: entry.source) == entry.destination else {
                throw failure("QQ 图片链接与设置不一致，保留本地备份，请恢复本地或检查配置。")
            }
            try ensureRemotePath(URL(fileURLWithPath: entry.destination), mountPoint: config.mountPoint, create: false)
            _ = try fm.contentsOfDirectory(atPath: entry.source)
        }
        return entries.count
    }
    static func manifest(_ root: URL) throws -> [String: String] {
        let root = root.resolvingSymlinksInPath()
        var result: [String: String] = [:]
        var enumerationError: Error?
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw failure("无法枚举图片缓存。") }
        for case let file as URL in iterator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw failure("图片缓存中含符号链接，停止迁移。") }
            if values.isRegularFile == true {
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                var hash = SHA256()
                while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
                let canonical = file.resolvingSymlinksInPath().path
                guard canonical.hasPrefix(root.path + "/") else { throw failure("图片路径越过缓存目录。") }
                result[String(canonical.dropFirst(root.path.count + 1))] = hash.finalize().map { String(format: "%02x", $0) }.joined()
            }
        }
        if let enumerationError { throw enumerationError }
        return result
    }
    // Journal is written before renaming. A crash at either step can be recovered without NAS access.
    static func migrateDirectory(source: URL, destination: URL, entries: inout [QQMigration], journalURL: URL, beforeSwitch: () throws -> Void = {}) throws {
        guard (try? fm.destinationOfSymbolicLink(atPath: source.path)) == nil else { throw failure("图片目录已经是链接，请先检查。") }
        guard !fm.fileExists(atPath: destination.path) else { throw failure("NAS 目标已存在，拒绝覆盖。") }
        try fm.copyItem(at: source, to: destination)
        let sourceManifest = try manifest(source), destinationManifest = try manifest(destination)
        guard sourceManifest == destinationManifest else {
            throw failure("图片校验失败；本机目录未改动。")
        }
        try beforeSwitch()
        let entry = QQMigration(source: source.path, backup: source.path + ".nas-backup-" + UUID().uuidString, destination: destination.path)
        entries.append(entry); try write(entries, at: journalURL)
        try fm.moveItem(atPath: entry.source, toPath: entry.backup)
        do { try fm.createSymbolicLink(atPath: entry.source, withDestinationPath: entry.destination) }
        catch { try fm.moveItem(atPath: entry.backup, toPath: entry.source); throw error }
    }
    static func migrate(_ config: Configuration) throws -> Int {
        try requireQQClosed(); try config.validate(forQQ: true)
        guard config.enabled else { throw failure("请先启用并保存 QQ 自动连接。") }
        var entries = try migrations()
        guard entries.isEmpty else { throw failure("已有迁移记录，请先检查连接或恢复本地。") }
        try mount(config)
        try ensureRemotePath(config.remoteRoot, mountPoint: config.mountPoint, create: true)
        let session = config.remoteRoot.appendingPathComponent("mac-" + UUID().uuidString)
        try ensureRemotePath(session, mountPoint: config.mountPoint, create: true)
        let accounts = try fm.contentsOfDirectory(at: accountRoot, includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.range(of: "^nt_qq_[a-fA-F0-9]+$", options: .regularExpression) != nil
        }
        for account in accounts {
            let source = account.appendingPathComponent("nt_data/Pic")
            guard fm.fileExists(atPath: source.path) else { continue }
            guard account.resolvingSymlinksInPath().path == account.path,
                  source.deletingLastPathComponent().resolvingSymlinksInPath().path == source.deletingLastPathComponent().path else {
                throw failure("QQ 账号目录包含符号链接，停止迁移。")
            }
            let targetParent = session.appendingPathComponent(account.lastPathComponent)
            try ensureRemotePath(targetParent, mountPoint: config.mountPoint, create: true)
            try migrateDirectory(source: source, destination: targetParent.appendingPathComponent("Pic"), entries: &entries, journalURL: journal, beforeSwitch: requireQQClosed)
        }
        guard !entries.isEmpty else { throw failure("没有找到可迁移的 QQ 图片缓存。请先登录 QQ 加载图片。") }
        return try probe(config)
    }
    // Offline-safe: restore the retained local copy; retain NAS data and links as recovery receipts.
    static func restore(entries: [QQMigration], journalURL: URL) throws {
        for entry in entries {
            let backup = URL(fileURLWithPath: entry.backup)
            let source = URL(fileURLWithPath: entry.source)
            guard fm.fileExists(atPath: backup.path) else {
                guard (try? fm.destinationOfSymbolicLink(atPath: entry.source)) == nil, fm.fileExists(atPath: entry.source) else {
                    throw failure("本地备份缺失，停止恢复。")
                }
                continue // Prepared journal before rename, or already restored after an interruption.
            }
            guard (try? fm.destinationOfSymbolicLink(atPath: entry.backup)) == nil else { throw failure("本地备份不能是链接。") }
            if let target = try? fm.destinationOfSymbolicLink(atPath: entry.source) {
                guard target == entry.destination else { throw failure("图片链接已被其他程序更改，停止恢复。") }
                // Rename the symlink itself; do not touch or traverse the NAS target.
                try fm.moveItem(at: source, to: source.deletingLastPathComponent().appendingPathComponent("Pic.nas-link-" + UUID().uuidString))
            } else if fm.fileExists(atPath: entry.source) { throw failure("本地图片目录已存在，拒绝覆盖。") }
            try fm.moveItem(at: backup, to: source)
        }
        try fm.moveItem(at: journalURL, to: journalURL.deletingLastPathComponent().appendingPathComponent("qq-restored-" + UUID().uuidString + ".json"))
    }
    static func restoreLocal() throws {
        try requireQQClosed()
        let entries = try migrations(); try validateJournal(entries)
        guard !entries.isEmpty else { throw failure("当前没有 QQ 迁移记录。") }
        try restore(entries: entries, journalURL: journal)
    }
}
