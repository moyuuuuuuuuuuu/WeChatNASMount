import AppKit
import Foundation
import ServiceManagement

struct Configuration: Codable, Sendable {
    var server: String
    var fallbackServer: String
    var share: String
    var username: String
    var mountPoint: String

    init(server: String = "", fallbackServer: String = "", share: String = "",
         username: String = NSUserName(),
         mountPoint: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/nas-wechat-storage").path) {
        self.server = server
        self.fallbackServer = fallbackServer
        self.share = share
        self.username = username
        self.mountPoint = mountPoint
    }

    enum CodingKeys: String, CodingKey {
        case server, fallbackServer, share, username, mountPoint
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
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
        guard let data = try? Data(contentsOf: AppPaths.config),
              let value = try? JSONDecoder().decode(Configuration.self, from: data) else {
            return Configuration()
        }
        return value
    }

    static func save(_ value: Configuration) throws {
        try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: AppPaths.config, options: .atomic)
    }

    static func output(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func isMounted(_ configuration: Configuration) -> Bool {
        guard let result = try? output("/sbin/mount", []) else { return false }
        return matchesMount(result.1, configuration)
    }

    static func matchesMount(_ listing: String, _ configuration: Configuration) -> Bool {
        listing.split(separator: "\n").contains { line in
            line.contains(" on \(configuration.mountPoint) (") && line.contains("smbfs,") &&
            [configuration.server, configuration.fallbackServer].filter { !$0.isEmpty }.contains { server in
                line.hasPrefix("//\(configuration.username)@\(server)/\(configuration.share) on ")
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
                      resolved.hasPrefix(configuration.mountPoint + "/") else {
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let server = NSTextField()
    private let fallbackServer = NSTextField()
    private let share = NSTextField()
    private let username = NSTextField()
    private let mountPoint = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var mounting = false
    private var failures = 0
    private var lastMessage = "等待检查"

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        loadFields()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateMenuIcon(healthy: nil)
        let menu = NSMenu()
        for (title, selector) in [("设置与状态", #selector(showSettings)), ("立即重试", #selector(retryNow)),
                                  ("关闭登录启动", #selector(disableLogin)), ("退出", #selector(quit))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
        if FileManager.default.fileExists(atPath: AppPaths.config.path) {
            window.orderOut(nil)
            retryNow()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(retryNow),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    @objc private func showSettings() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshStatus()
    }

    @objc private func disableLogin() {
        do { try SMAppService.mainApp.unregister(); refreshStatus() }
        catch { lastMessage = error.localizedDescription; refreshStatus() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func updateMenuIcon(healthy: Bool?) {
        guard let button = statusItem.button else { return }
        let symbol = healthy == false ? "exclamationmark.triangle" : "server.rack"
        let description = healthy.map { $0 ? "微信 NAS 已连接" : "微信 NAS 连接异常" } ?? "微信 NAS 正在连接"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        image?.isTemplate = true
        button.title = ""
        button.image = image
        button.imagePosition = .imageOnly
        button.alphaValue = healthy == nil ? 0.5 : 1
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    @objc private func retryNow() {
        guard !mounting else { return }
        timer?.invalidate()
        mounting = true
        lastMessage = "正在检查连接…"
        refreshStatus()
        let config = MountService.load()
        Task {
            let result = await Task.detached { () -> String in
                do {
                    try MountService.mount(config)
                    return "已连接，\(try MountService.verifyMedia(config)) 个媒体目录可读"
                } catch { return "连接失败：\(MountService.friendlyError(error))" }
            }.value
            mounting = false
            lastMessage = result
            let success = result.hasPrefix("已连接")
            failures = success ? 0 : min(failures + 1, 4)
            updateMenuIcon(healthy: success)
            statusItem.button?.toolTip = result
            refreshStatus()
            let delay = success ? 60.0 : min(30.0 * pow(2.0, Double(failures - 1)), 300.0)
            scheduleCheck(after: delay)
            if let data = try? JSONSerialization.data(withJSONObject: [
                "message": result, "healthy": success, "checkedAt": ISO8601DateFormatter().string(from: Date()),
                "loginEnabled": SMAppService.mainApp.status == .enabled
            ], options: [.sortedKeys]) {
                try? data.write(to: AppPaths.support.appendingPathComponent("status.json"), options: .atomic)
            }
        }
    }

    private func scheduleCheck(after delay: TimeInterval) {
        timer = Timer.scheduledTimer(timeInterval: delay, target: self,
            selector: #selector(retryNow), userInfo: nil, repeats: false)
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 470),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "微信 NAS 挂载"
        window.center()

        let title = NSTextField(labelWithString: "微信 NAS 挂载")
        title.font = .systemFont(ofSize: 24, weight: .semibold)

        let form = NSGridView(views: [
            [NSTextField(labelWithString: "主 NAS 地址"), server],
            [NSTextField(labelWithString: "备用 NAS 地址"), fallbackServer],
            [NSTextField(labelWithString: "共享名"), share],
            [NSTextField(labelWithString: "用户名"), username],
            [NSTextField(labelWithString: "沙盒挂载点"), mountPoint]
        ])
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 390
        form.rowSpacing = 10

        let mountButton = NSButton(title: "保存并启用自动连接", target: self, action: #selector(saveAndMount))
        mountButton.bezelStyle = .rounded
        let permissionButton = NSButton(title: "打开完全磁盘访问权限", target: self, action: #selector(openPrivacy))
        permissionButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [mountButton, permissionButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 6

        let note = NSTextField(wrappingLabelWithString:
            "适配微信版本：4.1.11。密码不会保存在本软件中。请先在 Finder 连接一次 SMB 共享并把密码存入钥匙串，然后授予本 App 完全磁盘访问权限。")
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, form, buttons, status, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26)
        ])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func loadFields() {
        let value = MountService.load()
        server.stringValue = value.server
        fallbackServer.stringValue = value.fallbackServer
        share.stringValue = value.share
        username.stringValue = value.username
        mountPoint.stringValue = value.mountPoint
    }

    private func configuration() -> Configuration {
        Configuration(server: server.stringValue.trimmingCharacters(in: .whitespaces),
                      fallbackServer: fallbackServer.stringValue.trimmingCharacters(in: .whitespaces),
                      share: share.stringValue.trimmingCharacters(in: .whitespaces),
                      username: username.stringValue.trimmingCharacters(in: .whitespaces),
                      mountPoint: mountPoint.stringValue.trimmingCharacters(in: .whitespaces))
    }

    @objc private func saveAndMount() {
        do {
            let value = configuration()
            try MountService.save(value)
            try SMAppService.mainApp.register()
            try MountService.retireLaunchAgent()
            retryNow()
        } catch {
            status.stringValue = "失败：\(error.localizedDescription)"
            status.textColor = .systemRed
        }
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    private func refreshStatus() {
        let login: String
        switch SMAppService.mainApp.status {
        case .enabled: login = "登录启动已启用"
        case .requiresApproval: login = "登录启动待批准，请在系统设置 → 通用 → 登录项中开启"
        default: login = "登录启动未启用"
        }
        status.stringValue = "\(lastMessage)\n\(login)"
        status.textColor = lastMessage.hasPrefix("连接失败") ? .systemRed : .secondaryLabelColor
    }
}

if CommandLine.arguments.contains("--status") || CommandLine.arguments.contains("--mount") ||
    CommandLine.arguments.contains("--enable-login") {
    do {
        if CommandLine.arguments.contains("--enable-login") {
            try SMAppService.mainApp.register()
            try MountService.retireLaunchAgent()
        }
        let config = MountService.load()
        if CommandLine.arguments.contains("--mount") { try MountService.mount(config) }
        let mounted = MountService.isMounted(config)
        let count = mounted ? try MountService.verifyMedia(config) : 0
        let data = try JSONSerialization.data(withJSONObject: [
            "mounted": mounted, "readableMediaDirectories": count,
            "loginEnabled": SMAppService.mainApp.status == .enabled,
            "loginRequiresApproval": SMAppService.mainApp.status == .requiresApproval
        ], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(mounted ? 0 : 1)
    } catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
