import AppKit
import Foundation
import ServiceManagement

struct Configuration: Codable, Sendable {
    var enabled: Bool
    var remoteDirectory: String
    var server: String
    var fallbackServer: String
    var share: String
    var username: String
    var mountPoint: String

    init(enabled: Bool = true, remoteDirectory: String = "", server: String = "", fallbackServer: String = "", share: String = "",
         username: String = NSUserName(),
         mountPoint: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/nas-wechat-storage").path) {
        self.enabled = enabled
        self.remoteDirectory = remoteDirectory
        self.server = server
        self.fallbackServer = fallbackServer
        self.share = share
        self.username = username
        self.mountPoint = mountPoint
    }

    enum CodingKeys: String, CodingKey {
        case enabled, remoteDirectory, server, fallbackServer, share, username, mountPoint
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        remoteDirectory = try values.decodeIfPresent(String.self, forKey: .remoteDirectory) ?? ""
        server = try values.decode(String.self, forKey: .server)
        fallbackServer = try values.decodeIfPresent(String.self, forKey: .fallbackServer) ?? ""
        share = try values.decode(String.self, forKey: .share)
        username = try values.decode(String.self, forKey: .username)
        mountPoint = try values.decode(String.self, forKey: .mountPoint)
    }
}

enum AppPaths {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WeChatNASMount")
    static let config = support.appendingPathComponent("config.json")
    static let launchAgent = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/ink.moyuu.wechat-nas-mount.plist")
}

enum MountService {
    static func load() -> Configuration {
        SettingsStore.load().wechat
    }

    static func save(_ value: Configuration) throws {
        var settings = SettingsStore.load()
        settings.wechat = value
        try SettingsStore.save(settings)
    }

    static func output(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        try CommandRunner.run(executable, arguments)
    }

    static func isMounted(_ configuration: Configuration) -> Bool {
        guard let result = try? output("/sbin/mount", []) else { return false }
        return matchesMount(result.1, configuration)
    }

    static func matchesMount(_ listing: String, _ configuration: Configuration) -> Bool {
        listing.split(separator: "\n").contains { raw in
            let line = String(raw)
            guard let split = line.range(of: " on "), line.contains(" on \(configuration.mountPoint) ("), line.contains("smbfs,") else { return false }
            let remote = String(line[..<split.lowerBound]).removingPercentEncoding ?? String(line[..<split.lowerBound])
            return [configuration.server, configuration.fallbackServer].filter { !$0.isEmpty }.contains { server in
                remote == "//\(configuration.username)@\(server)/\(configuration.share)"
            }
        }
    }

    static func verifyMedia(_ configuration: Configuration) throws -> Int {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: configuration.mountPoint).deletingLastPathComponent()
            .appendingPathComponent("xwechat_files")
        var count = 0
        for account in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let paths = ["attach", "video", "file"].map { account.appendingPathComponent("msg/\($0)").path }
            guard paths.contains(where: { (try? fm.destinationOfSymbolicLink(atPath: $0)) != nil }) else { continue }
            for name in ["attach", "video", "file"] {
                let path = account.appendingPathComponent("msg/\(name)").path
                guard let target = try? fm.destinationOfSymbolicLink(atPath: path) else {
                    throw NSError(domain: "WeChatNASMount", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "媒体链接缺失：\(name)"])
                }
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                guard target.hasPrefix(configuration.mountPoint + "/"),
                      resolved.hasPrefix(configuration.mountPoint + "/"),
                      resolved.hasPrefix(configuration.remoteRoot.path + "/") else {
                    throw NSError(domain: "WeChatNASMount", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "媒体链接指向其他位置：\(name)"])
                }
                _ = try fm.contentsOfDirectory(atPath: path)
                count += 1
            }
        }
        guard count > 0 else {
            throw NSError(domain: "WeChatNASMount", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "NAS 已连接，但没有找到媒体链接，请检查配置。"])
        }
        return count
    }

    static func friendlyError(_ error: Error) -> String {
        let value = error as NSError
        let message = error.localizedDescription
        if (value.domain == NSCocoaErrorDomain && [257, 513].contains(value.code)) ||
            message.contains("Operation not permitted") {
            return "请在系统设置中为本 App 开启完全磁盘访问权限；升级后可能需要移除旧条目并重新添加。\n\(message)"
        }
        if message.contains("Authentication error") {
            return "NAS 认证失败，请在 Finder 连接对应地址并更新钥匙串凭据。\n\(message)"
        }
        return message
    }

    static func notifyMounted(using fallback: Bool) {
        let route = fallback ? "备用地址" : "主地址"
        let script = "display notification \"已通过\(route)挂载，可以正常使用微信图片、视频和文件。\" with title \"微信 NAS 已连接\" sound name \"default\""
        _ = try? output("/usr/bin/osascript", ["-e", script])
    }

    static func mount(_ configuration: Configuration) throws {
        try configuration.validate(forQQ: false)
        guard !configuration.server.isEmpty, !configuration.share.isEmpty else {
            throw NSError(domain: "WeChatNASMount", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请填写 NAS 地址和共享名。"])
        }
        if isMounted(configuration) { _ = try verifyMedia(configuration); return }
        if let mounts = try? output("/sbin/mount", []), mounts.1.contains(" on \(configuration.mountPoint) (") {
            throw NSError(domain: "WeChatNASMount", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "挂载点已被其他共享占用，请检查配置。"])
        }
        try FileManager.default.createDirectory(
            atPath: configuration.mountPoint,
            withIntermediateDirectories: true
        )
        let servers = [configuration.server, configuration.fallbackServer]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var errors: [String] = []
        for (index, server) in servers.enumerated() {
            let remote = "//\(configuration.username)@\(server)/\(configuration.share)"
            let result = try output("/sbin/mount_smbfs", [
                "-N", "-o", "nobrowse,noowners", remote, configuration.mountPoint
            ])
            if result.0 == 0 && isMounted(configuration) {
                _ = try verifyMedia(configuration)
                notifyMounted(using: index > 0)
                return
            }
            errors.append("\(server)：\(result.1.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        throw NSError(domain: "WeChatNASMount", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: "\n")])
    }

    static func retireLaunchAgent() throws {
        let domain = "gui/\(getuid())"
        _ = try? output("/bin/launchctl", ["bootout", "\(domain)/ink.moyuu.wechat-nas-mount"])
        if FileManager.default.fileExists(atPath: AppPaths.launchAgent.path) {
            try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
            let backup = AppPaths.support.appendingPathComponent("legacy-agent-\(UUID().uuidString).plist")
            try FileManager.default.moveItem(at: AppPaths.launchAgent, to: backup)
        }
    }
}

enum MenuIcon {
    static func storageBridge() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.scaleBy(x: 0.75, y: 0.75)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(1.55)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: 10.5, y: 14.8))
            context.addLine(to: CGPoint(x: 14.7, y: 14.8))
            context.addCurve(to: CGPoint(x: 18, y: 11.5),
                control1: CGPoint(x: 16.5, y: 14.8), control2: CGPoint(x: 18, y: 13.3))
            context.addLine(to: CGPoint(x: 18, y: 10.1))
            context.strokePath()
            for (x, y) in [(1.5, 12.0), (13.5, 4.5)] {
                context.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: 9, height: 5.6),
                    cornerWidth: 1.65, cornerHeight: 1.65, transform: nil))
                context.strokePath()
                context.fillEllipse(in: CGRect(x: x + 1.9, y: y + 2.2, width: 1.2, height: 1.2))
                context.move(to: CGPoint(x: x + 4.8, y: y + 2.8))
                context.addLine(to: CGPoint(x: x + 6.3, y: y + 2.8))
                context.strokePath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}


// Worker processes isolate network filesystem calls from the GUI and from the other app.
if let index = CommandLine.arguments.firstIndex(of: "--check-profile"), CommandLine.arguments.count > index + 1 {
    do {
        let settings = try SettingsStore.read()
        switch CommandLine.arguments[index + 1] {
        case "wechat":
            guard settings.wechat.enabled else { throw failure("微信自动连接未启用。") }
            try MountService.mount(settings.wechat)
            print("已连接，\(try MountService.verifyMedia(settings.wechat)) 个微信媒体目录可读")
        case "qq":
            guard settings.qq.enabled else { throw failure("QQ 自动连接未启用。") }
            try QQService.mount(settings.qq)
            let count = try QQService.probe(settings.qq)
            print(count == 0 ? "NAS 已连接，尚未迁移 QQ 图片" : "已连接，\(count) 个 QQ 图片目录可读")
        case "feishu":
            guard settings.feishu.enabled else { throw failure("飞书自动连接未启用。") }
            try FeishuService.mount(settings.feishu)
            let count = try FeishuService.probe(settings.feishu)
            print(count == 0 ? "NAS 已连接，尚未迁移飞书图片" : "已连接，\(count) 个飞书图片目录可读")
        default: throw failure("未知应用。")
        }
        exit(0)
    } catch { print(MountService.friendlyError(error)); exit(1) }
}
if CommandLine.arguments.contains("--feishu-migrate") || CommandLine.arguments.contains("--feishu-restore") {
    do {
        let lock = try QQMutationLock(name: "feishu"); defer { lock.release() }
        if CommandLine.arguments.contains("--feishu-restore") {
            try FeishuService.restoreLocal(); print("已恢复飞书本地图片；原始本地备份与 NAS 副本保留")
        } else { print("迁移成功，\(try FeishuService.migrate(SettingsStore.read().feishu)) 个飞书图片目录已校验") }
        exit(0)
    } catch { print(MountService.friendlyError(error)); exit(1) }
}
if CommandLine.arguments.contains("--qq-migrate") || CommandLine.arguments.contains("--qq-restore") {
    do {
        let lock = try QQMutationLock(); defer { lock.release() }
        if CommandLine.arguments.contains("--qq-restore") { try QQService.restoreLocal(); print("已恢复 QQ 本地图片；NAS 副本保留") }
        else { print("迁移成功，\(try QQService.migrate(SettingsStore.read().qq)) 个 QQ 图片目录已校验") }
        exit(0)
    } catch { print(MountService.friendlyError(error)); exit(1) }
}
if CommandLine.arguments.contains("--status") || CommandLine.arguments.contains("--mount") || CommandLine.arguments.contains("--enable-login") {
    do {
        if CommandLine.arguments.contains("--enable-login") {
            try SMAppService.mainApp.register(); try MountService.retireLaunchAgent()
        }
        let settings = try SettingsStore.read()
        if CommandLine.arguments.contains("--mount"), settings.wechat.enabled { try MountService.mount(settings.wechat) }
        if CommandLine.arguments.contains("--mount"), settings.qq.enabled { try QQService.mount(settings.qq) }
        if CommandLine.arguments.contains("--mount"), settings.feishu.enabled { try FeishuService.mount(settings.feishu) }
        let mounted = MountService.isMounted(settings.wechat)
        // Run all potentially blocking filesystem checks in bounded subprocesses.
        var count = 0; var wechatError = ""
        if mounted {
            do {
                count = Int(try CommandRunner.worker(["--verify-wechat"])) ?? 0
            } catch { wechatError = error.localizedDescription }
        }
        var qqStatus: [String: Any] = ["enabled": settings.qq.enabled, "mounted": MountService.isMounted(settings.qq)]
        if settings.qq.enabled {
            do {
                let readable = Int(try CommandRunner.worker(["--verify-qq"])) ?? 0
                qqStatus["readableMediaDirectories"] = readable; qqStatus["healthy"] = true
            }
            catch { qqStatus["message"] = error.localizedDescription; qqStatus["healthy"] = false }
        }
        var feishuStatus: [String: Any] = ["enabled": settings.feishu.enabled, "mounted": MountService.isMounted(settings.feishu)]
        if settings.feishu.enabled {
            do {
                let readable = Int(try CommandRunner.worker(["--verify-feishu"])) ?? 0
                feishuStatus["readableMediaDirectories"] = readable; feishuStatus["healthy"] = true
            } catch { feishuStatus["message"] = error.localizedDescription; feishuStatus["healthy"] = false }
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "mounted": mounted, "readableMediaDirectories": count, "wechatError": wechatError, "qq": qqStatus, "feishu": feishuStatus,
            "loginEnabled": SMAppService.mainApp.status == .enabled,
            "loginRequiresApproval": SMAppService.mainApp.status == .requiresApproval
        ], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self)); exit((!settings.wechat.enabled || (mounted && count > 0)) && (qqStatus["healthy"] as? Bool ?? true) && (feishuStatus["healthy"] as? Bool ?? true) ? 0 : 1)
    } catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
}
if CommandLine.arguments.contains("--verify-feishu") {
    do { print(try FeishuService.probe(SettingsStore.read().feishu)); exit(0) }
    catch { print(error.localizedDescription); exit(1) }
}
if CommandLine.arguments.contains("--verify-qq") {
    do { print(try QQService.probe(SettingsStore.read().qq)); exit(0) }
    catch { print(error.localizedDescription); exit(1) }
}
if CommandLine.arguments.contains("--verify-wechat") {
    do { print(try MountService.verifyMedia(SettingsStore.read().wechat)); exit(0) }
    catch { print(error.localizedDescription); exit(1) }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
