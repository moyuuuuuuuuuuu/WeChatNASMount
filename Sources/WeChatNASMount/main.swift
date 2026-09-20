import AppKit
import Foundation

struct Configuration: Codable {
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
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func isMounted(_ configuration: Configuration) -> Bool {
        guard let result = try? output("/sbin/mount", []) else { return false }
        return result.1.contains(" on \(configuration.mountPoint) (")
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
        if isMounted(configuration) { return }
        try FileManager.default.createDirectory(
            atPath: configuration.mountPoint,
            withIntermediateDirectories: true
        )
        let servers = [configuration.server, configuration.fallbackServer]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var finalResult: (Int32, String) = (1, "无法连接 NAS。")
        for (index, server) in servers.enumerated() {
            let remote = "//\(configuration.username)@\(server)/\(configuration.share)"
            finalResult = try output("/sbin/mount_smbfs", [
                "-N", "-o", "nobrowse,noowners", remote, configuration.mountPoint
            ])
            if finalResult.0 == 0 {
                notifyMounted(using: index > 0)
                return
            }
        }
        throw NSError(domain: "WeChatNASMount", code: Int(finalResult.0),
                      userInfo: [NSLocalizedDescriptionKey: finalResult.1.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    static func installLaunchAgent(appPath: String) throws {
        let executable = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/MacOS/WeChatNASMount").path
        let plist: [String: Any] = [
            "Label": "ink.moyuu.wechat-nas-mount",
            "ProgramArguments": [executable, "--mount"],
            "RunAtLoad": true,
            "StartInterval": 30,
            "StandardOutPath": AppPaths.support.appendingPathComponent("mount.log").path,
            "StandardErrorPath": AppPaths.support.appendingPathComponent("mount-error.log").path
        ]
        try FileManager.default.createDirectory(
            at: AppPaths.launchAgent.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: AppPaths.launchAgent, options: .atomic)

        let domain = "gui/\(getuid())"
        _ = try? output("/bin/launchctl", ["bootout", "\(domain)/ink.moyuu.wechat-nas-mount"])
        let result = try output("/bin/launchctl", ["bootstrap", domain, AppPaths.launchAgent.path])
        guard result.0 == 0 else {
            throw NSError(domain: "WeChatNASMount", code: Int(result.0),
                          userInfo: [NSLocalizedDescriptionKey: result.1])
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--mount") {
            try? MountService.mount(MountService.load())
            NSApplication.shared.terminate(nil)
            return
        }
        buildWindow()
        loadFields()
        refreshStatus()
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 390),
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

        let mountButton = NSButton(title: "保存并立即挂载", target: self, action: #selector(saveAndMount))
        mountButton.bezelStyle = .rounded
        let permissionButton = NSButton(title: "打开完全磁盘访问权限", target: self, action: #selector(openPrivacy))
        permissionButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [mountButton, permissionButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3

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
            try MountService.installLaunchAgent(appPath: Bundle.main.bundlePath)
            try MountService.mount(value)
            refreshStatus()
        } catch {
            status.stringValue = "失败：\(error.localizedDescription)"
            status.textColor = .systemRed
        }
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    private func refreshStatus() {
        let mounted = MountService.isMounted(configuration())
        status.stringValue = mounted ? "状态：NAS 已挂载，自动重试已启用。" : "状态：尚未挂载。"
        status.textColor = mounted ? .systemGreen : .secondaryLabelColor
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
