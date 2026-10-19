import Foundation

enum FeishuService {
    static var fm: FileManager { FileManager.default }
    static let journal = AppPaths.support.appendingPathComponent("feishu-migrations.json")
    static let accountRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LarkShell/sdk_storage")

    static func validate(_ config: Configuration) throws {
        try config.validate(forQQ: false)
        guard config.mountPoint == Configuration.feishuDefault.mountPoint else {
            throw failure("飞书必须使用独立的固定挂载点，不能复用微信或 QQ 挂载点。")
        }
    }
    static func requireClosed() throws {
        let result = try CommandRunner.run("/usr/bin/pgrep", ["-x", "Feishu"])
        guard result.0 == 1 else { throw failure("请先完全退出飞书，再迁移或恢复图片缓存。") }
    }
    static func entries(at url: URL = journal) throws -> [QQMigration] { try QQService.migrations(at: url) }
    static func validateEntries(_ records: [QQMigration], root: URL = accountRoot) throws {
        for entry in records {
            let source = URL(fileURLWithPath: entry.source)
            let account = source.deletingLastPathComponent().deletingLastPathComponent()
            guard account.deletingLastPathComponent().path == root.path,
                  account.lastPathComponent.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil,
                  source.path == account.appendingPathComponent("resources/images").path,
                  source.deletingLastPathComponent().resolvingSymlinksInPath().path == source.deletingLastPathComponent().path,
                  entry.backup.hasPrefix(entry.source + ".nas-backup-"),
                  URL(fileURLWithPath: entry.backup).deletingLastPathComponent().path == source.deletingLastPathComponent().path else {
                throw failure("飞书迁移记录越过图片缓存范围，已停止操作。")
            }
        }
    }
    static func assertConfigurationUnchanged(_ old: Configuration, _ new: Configuration, records: [QQMigration]? = nil) throws {
        let active = try records ?? entries()
        guard !active.isEmpty else { return }
        guard NASConnection(old) == NASConnection(new), old.share == new.share,
              old.remoteDirectory == new.remoteDirectory, old.mountPoint == new.mountPoint, new.enabled else {
            throw failure("飞书已有迁移记录，请先恢复本地图片，再更改 NAS 连接、存储位置或关闭自动连接。")
        }
    }
    static func mount(_ config: Configuration) throws { try QQService.mount(config, forFeishu: true) }
    static func probe(_ config: Configuration) throws -> Int {
        try validate(config)
        guard MountService.isMounted(config) else { throw failure("飞书 NAS 未挂载；保留链接和本地备份，稍后重试。") }
        _ = try fm.contentsOfDirectory(atPath: config.mountPoint)
        let records = try entries(); try validateEntries(records)
        for record in records {
            guard record.destination.hasPrefix(config.remoteRoot.path + "/"),
                  try fm.destinationOfSymbolicLink(atPath: record.source) == record.destination else {
                throw failure("飞书图片链接与配置不一致，请检查或恢复本地图片。")
            }
            try QQService.ensureRemotePath(URL(fileURLWithPath: record.destination), mountPoint: config.mountPoint, create: false)
            _ = try fm.contentsOfDirectory(atPath: record.source)
        }
        return records.count
    }
    static func migrate(_ config: Configuration) throws -> Int {
        try requireClosed(); try validate(config)
        guard config.enabled else { throw failure("请先启用并保存飞书设置。") }
        var records = try entries()
        guard records.isEmpty else { throw failure("飞书已有迁移记录，请先检查连接或恢复本地。") }
        let sources = try fm.contentsOfDirectory(at: accountRoot, includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil
        }.map { $0.appendingPathComponent("resources/images") }.filter { fm.fileExists(atPath: $0.path) }
        guard !sources.isEmpty else { throw failure("未找到飞书图片缓存，请先登录飞书并加载聊天图片。") }
        // Preflight every source before making any NAS or local data changes.
        for source in sources {
            guard source.resolvingSymlinksInPath().path == source.path else { throw failure("飞书图片目录含符号链接，请先检查现有迁移。") }
            _ = try QQService.manifest(source)
        }
        try mount(config)
        try QQService.ensureRemotePath(config.remoteRoot, mountPoint: config.mountPoint, create: true)
        let session = config.remoteRoot.appendingPathComponent("mac-" + UUID().uuidString)
        try QQService.ensureRemotePath(session, mountPoint: config.mountPoint, create: true)
        for source in sources {
            let account = source.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            let parent = session.appendingPathComponent(account)
            try QQService.ensureRemotePath(parent, mountPoint: config.mountPoint, create: true)
            try QQService.migrateDirectory(source: source, destination: parent.appendingPathComponent("images"),
                entries: &records, journalURL: journal, beforeSwitch: requireClosed)
        }
        return try probe(config)
    }
    // Read only local backup data so this works even with a hung or missing NAS.
    // The original backup is copied, not consumed. New NAS images remain on the NAS.
    static func restore(records: [QQMigration], journalURL: URL) throws {
        for record in records {
            let source = URL(fileURLWithPath: record.source), backup = URL(fileURLWithPath: record.backup)
            guard (try? fm.destinationOfSymbolicLink(atPath: backup.path)) == nil else { throw failure("飞书本地备份不能是链接。") }
            let link = try? fm.destinationOfSymbolicLink(atPath: source.path)
            if link == nil, fm.fileExists(atPath: source.path) {
                // Prepared-before-rename journal or completed restore from an interrupted run.
                guard (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                    throw failure("飞书图片位置不是目录，停止恢复。")
                }
                continue
            }
            guard fm.fileExists(atPath: backup.path) else { throw failure("飞书本地备份缺失，停止恢复。") }
            if let link, link != record.destination { throw failure("飞书图片链接被更改，停止恢复。") }
            let stage = source.deletingLastPathComponent().appendingPathComponent("images.restore-" + UUID().uuidString)
            try fm.copyItem(at: backup, to: stage)
            guard try QQService.manifest(stage) == QQService.manifest(backup) else { throw failure("飞书本地恢复校验失败。") }
            if link != nil {
                try fm.moveItem(at: source, to: source.deletingLastPathComponent().appendingPathComponent("images.nas-link-" + UUID().uuidString))
            }
            try fm.moveItem(at: stage, to: source)
        }
        try fm.moveItem(at: journalURL, to: journalURL.deletingLastPathComponent().appendingPathComponent("feishu-restored-" + UUID().uuidString + ".json"))
    }
    static func restoreLocal() throws {
        try requireClosed()
        let records = try entries(); try validateEntries(records)
        guard !records.isEmpty else { throw failure("当前没有飞书迁移记录。") }
        try restore(records: records, journalURL: journal)
    }
}

enum ReconnectPolicy {
    static func delay(failures: Int) -> TimeInterval {
        failures == 0 ? 60 : min(30 * pow(2, Double(min(max(failures, 1), 5) - 1)), 300)
    }
}
