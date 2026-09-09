import AppKit
import Foundation

struct Configuration: Codable {
    var server = ""
    var share = ""
    var username = NSUserName()
    var mountPoint = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/nas-wechat-storage").path
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
        let remote = "//\(configuration.username)@\(configuration.server)/\(configuration.share)"
        let result = try output("/sbin/mount_smbfs", [
            "-N", "-o", "nobrowse,noowners", remote, configuration.mountPoint
        ])
        guard result.0 == 0 else {
            throw NSError(domain: "WeChatNASMount", code: Int(result.0),
                          userInfo: [NSLocalizedDescriptionKey: result.1.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "微信 NAS 挂载"
        window.center()

        let title = NSTextField(labelWithString: "微信 NAS 挂载")
        title.font = .systemFont(ofSize: 24, weight: .semibold)

        let form = NSGridView(views: [
            [NSTextField(labelWithString: "NAS 地址"), server],
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
        share.stringValue = value.share
        username.stringValue = value.username
        mountPoint.stringValue = value.mountPoint
    }

    private func configuration() -> Configuration {
        Configuration(server: server.stringValue.trimmingCharacters(in: .whitespaces),
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
