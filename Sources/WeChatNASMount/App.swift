import AppKit
import Foundation
import ServiceManagement
import Network

@MainActor
final class ProfileFields {
    let enabled = NSButton(checkboxWithTitle: "启用自动连接", target: nil, action: nil)
    let server = NSTextField(), fallback = NSTextField(), share = NSTextField(), user = NSTextField(), folder = NSTextField()
    let status = NSTextField(wrappingLabelWithString: "尚未检查")
    func load(_ config: Configuration) {
        enabled.state = config.enabled ? .on : .off
        server.stringValue = config.server; fallback.stringValue = config.fallbackServer
        share.stringValue = config.share; user.stringValue = config.username; folder.stringValue = config.remoteDirectory
    }
    func config(base: Configuration) -> Configuration {
        var result = base
        result.enabled = enabled.state == .on
        result.server = server.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.fallbackServer = fallback.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.share = share.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.username = user.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.remoteDirectory = folder.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
    func view(name: String, note: String, actions: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: name + "存储设置")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "NAS 地址"), server],
            [NSTextField(labelWithString: "备用地址"), fallback],
            [NSTextField(labelWithString: "共享名"), share],
            [NSTextField(labelWithString: "用户名"), user],
            [NSTextField(labelWithString: "远端目录"), folder]
        ])
        grid.column(at: 0).xPlacement = .trailing; grid.column(at: 1).width = 430
        grid.rowSpacing = 12
        folder.placeholderString = "共享内的相对路径，留空表示共享根目录"
        let help = NSTextField(wrappingLabelWithString: note)
        help.textColor = .secondaryLabelColor
        let bar = NSStackView(views: actions); bar.spacing = 12
        status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 4
        let stack = NSStackView(views: [heading, enabled, grid, help, bar, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        let container = NSView(); stack.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24)
        ])
        return container
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var item: NSStatusItem!
    private let wechat = ProfileFields(), qq = ProfileFields()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private var settings = Settings()
    private var timer: Timer?
    private let network = NWPathMonitor()
    private var busy: Set<String> = []
    private var failures: [String: Int] = [:]
    private var due: [String: Date] = [:]
    private var messages: [String: String] = [:]
    private var healthy: [String: Bool] = [:]
    private var configError: String?
    private var controls: [NSControl] = []
    private var mutationBusy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { settings = try SettingsStore.read() } catch { configError = error.localizedDescription }
        buildWindow(); wechat.load(settings.wechat); qq.load(settings.qq)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuIcon.storageBridge()
        let menu = NSMenu()
        for (title, action) in [("设置与状态", #selector(showSettings)), ("立即重试", #selector(retryNow)),
            ("关闭登录启动", #selector(disableLogin)), ("退出", #selector(quit))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
        }
        item.menu = menu
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(retryNow), name: NSWorkspace.didWakeNotification, object: nil)
        network.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in self?.retryNow() }
        }
        network.start(queue: DispatchQueue(label: "nas-network"))
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkDue() }
        }
        if FileManager.default.fileExists(atPath: AppPaths.config.path), configError == nil { window.orderOut(nil) }
        else { showSettings() }
        refresh(); retryNow()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Do not abandon a migration between journal and link installation.
        if mutationBusy { showSettings(); summary.stringValue = "迁移或恢复正在进行，请等待完成后退出。"; return .terminateCancel }
        return .terminateNow
    }
    @objc private func showSettings() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func disableLogin() {
        do { try SMAppService.mainApp.unregister(); refresh() } catch { show(error) }
    }
    private func show(_ error: Error) { summary.stringValue = MountService.friendlyError(error); summary.textColor = .systemRed; showSettings() }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let value = NSButton(title: title, target: self, action: action); value.bezelStyle = .rounded; controls.append(value); return value
    }
    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 680),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "聊天 NAS · 微信与 QQ"; window.center(); window.isReleasedWhenClosed = false
        let tabs = NSTabView()
        let w = NSTabViewItem(identifier: "wechat"); w.label = "微信"
        w.view = wechat.view(name: "微信", note: "适配微信版本：4.1.11。沿用原有沙盒挂载点与媒体链接。远端目录用于校验已有链接的存储范围；更改后不会自动搬动微信数据。", actions: [])
        let q = NSTabViewItem(identifier: "qq"); q.label = "QQ"
        q.view = qq.view(name: "QQ", note: "适配 QQ 版本：6.9.98。仅迁移聊天图片缓存，数据库留在本机；下载文件位置仍由 QQ 管理。迁移和恢复前请退出 QQ。本地备份会保留；恢复本地不会合并迁移后的 NAS 新图片，NAS 原件仍保留。", actions: [button("迁移 QQ 图片到 NAS", #selector(migrateQQ)), button("恢复 QQ 本地图片", #selector(restoreQQ))])
        tabs.addTabViewItem(w); tabs.addTabViewItem(q)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let actions = NSStackView(views: [button("保存设置", #selector(save)), button("启用登录启动", #selector(enableLogin)), button("立即检查", #selector(retryNow)), button("磁盘访问权限", #selector(openPrivacy))])
        actions.spacing = 10; actions.translatesAutoresizingMaskIntoConstraints = false
        summary.maximumNumberOfLines = 4; summary.textColor = .secondaryLabelColor; summary.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); window.contentView = content
        for view in [tabs, actions, summary] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), tabs.heightAnchor.constraint(equalToConstant: 505),
            actions.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 16), actions.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            summary.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 14), summary.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: tabs.trailingAnchor), summary.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16)
        ])
    }
    @objc private func openPrivacy() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
    @objc private func save() {
        guard busy.isEmpty else { return }
        do {
            if let configError { throw failure("配置读取失败，先修复原配置文件：\(configError)") }
            let updated = Settings(wechat: wechat.config(base: settings.wechat), qq: qq.config(base: settings.qq))
            if updated.wechat.enabled { try updated.wechat.validate(forQQ: false) }
            if updated.qq.enabled { try updated.qq.validate(forQQ: true) }
            let lock = try QQMutationLock(); defer { lock.release() }
            try QQService.assertConfigurationUnchanged(settings.qq, updated.qq)
            // Never silently relocate existing WeChat links or replace its live mount.
            if MountService.isMounted(settings.wechat),
               (updated.wechat.mountPoint != settings.wechat.mountPoint || updated.wechat.server != settings.wechat.server ||
                updated.wechat.share != settings.wechat.share || updated.wechat.username != settings.wechat.username ||
                updated.wechat.remoteDirectory != settings.wechat.remoteDirectory) {
                throw failure("微信当前已挂载。变更服务器、共享、远端目录或挂载点前，请先退出微信并准备好对应的媒体链接及挂载；现有连接保持不变。")
            }
            try SettingsStore.save(updated); settings = updated; summary.textColor = .secondaryLabelColor
            retryNow()
        } catch { show(error) }
    }
    @objc private func enableLogin() {
        do { try SMAppService.mainApp.register(); try MountService.retireLaunchAgent(); refresh() } catch { show(error) }
    }
    @objc private func retryNow() { due = [:]; checkDue() }
    private func checkDue() {
        guard configError == nil, !mutationBusy else { return }
        for (key, config) in [("wechat", settings.wechat), ("qq", settings.qq)] {
            guard config.enabled, !busy.contains(key), (due[key] ?? .distantPast) <= Date() else { continue }
            busy.insert(key); messages[key] = "正在检查…"; refresh()
            Task {
                let result = await Task.detached { () -> Result<String, Error> in
                    Result { try CommandRunner.worker(["--check-profile", key]) }
                }.value
                busy.remove(key)
                switch result {
                case .success(let message): messages[key] = message; healthy[key] = true; failures[key] = 0
                case .failure(let error): messages[key] = MountService.friendlyError(error); healthy[key] = false; failures[key] = min((failures[key] ?? 0) + 1, 5)
                }
                let count = failures[key] ?? 0
                due[key] = Date().addingTimeInterval(count == 0 ? 60 : min(30 * pow(2, Double(count - 1)), 300))
                refresh(); writeStatus()
            }
        }
        refresh()
    }
    private func refresh() {
        wechat.status.stringValue = settings.wechat.enabled ? (messages["wechat"] ?? "等待检查") : "微信自动连接已关闭"
        qq.status.stringValue = settings.qq.enabled ? (messages["qq"] ?? "等待检查") : "QQ 自动连接已关闭，尚未迁移图片"
        for (key, field) in [("wechat", wechat), ("qq", qq)] { field.status.textColor = healthy[key] == false ? .systemRed : .secondaryLabelColor }
        controls.forEach { $0.isEnabled = busy.isEmpty }
        let login: String
        switch SMAppService.mainApp.status {
        case .enabled: login = "登录启动已启用"
        case .requiresApproval: login = "请在系统设置 → 通用 → 登录项中批准启动"
        default: login = "登录启动未启用"
        }
        summary.stringValue = configError.map { "配置读取失败，未执行自动连接：\($0)" } ?? "\(login) · 网络恢复及唤醒后自动检查\n密码沿用系统 SMB 凭据，不保存在客户端。"
        let enabled = [("wechat", settings.wechat), ("qq", settings.qq)].filter { $0.1.enabled }.map { $0.0 }
        let failed = enabled.contains { healthy[$0] == false }
        item?.button?.image = failed ? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "NAS 连接异常") : MenuIcon.storageBridge()
        item?.button?.toolTip = "微信：\(wechat.status.stringValue)\nQQ：\(qq.status.stringValue)"
    }
    private func writeStatus() {
        let active = [("wechat", settings.wechat), ("qq", settings.qq)].filter { $0.1.enabled }.map { $0.0 }
        let object: [String: Any] = [
            "message": active.map { "\($0)：\(messages[$0] ?? "等待检查")" }.joined(separator: "\n"),
            "healthy": active.allSatisfy { healthy[$0] == true },
            "checkedAt": ISO8601DateFormatter().string(from: Date()),
            "loginEnabled": SMAppService.mainApp.status == .enabled,
            "profiles": messages
        ]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
            try? data.write(to: AppPaths.support.appendingPathComponent("status.json"), options: .atomic)
        }
    }
    @objc private func migrateQQ() { mutateQQ(restore: false) }
    @objc private func restoreQQ() { mutateQQ(restore: true) }
    private func mutateQQ(restore: Bool) {
        guard busy.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = restore ? "恢复 QQ 本地图片？" : "迁移 QQ 聊天图片到 NAS？"
        alert.informativeText = restore ? "请先退出 QQ。恢复迁移前的本地副本，NAS 上后来新增的图片仍保留在 NAS，不会自动合并。数据库和下载目录不变。" : "请先退出 QQ 并保存设置。将复制所有检测到账号的 Pic 目录，校验后建立链接，并保留本地完整备份。断网时图片可能无法加载。"
        alert.addButton(withTitle: restore ? "恢复本地" : "开始迁移"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !restore {
            let draft = qq.config(base: settings.qq)
            if draft.enabled != settings.qq.enabled || draft.remoteDirectory != settings.qq.remoteDirectory ||
                draft.server != settings.qq.server || draft.fallbackServer != settings.qq.fallbackServer ||
                draft.share != settings.qq.share || draft.username != settings.qq.username {
                show(failure("请先保存 QQ 设置，再迁移。")); return
            }
        }
        startQQMutation(restore: restore)
    }
    private func startQQMutation(restore: Bool) {
        busy.insert("qq"); mutationBusy = true; messages["qq"] = restore ? "正在恢复本地…" : "正在复制与校验图片…"; refresh()
        Task {
            let result = await Task.detached { () -> Result<String, Error> in
                Result { try CommandRunner.worker([restore ? "--qq-restore" : "--qq-migrate"], timeout: 600) }
            }.value
            busy.remove("qq"); mutationBusy = false
            switch result {
            case .success(let message): messages["qq"] = message; healthy["qq"] = true
            case .failure(let error): messages["qq"] = "\(error.localizedDescription)\n如迁移中断，可退出 QQ 后使用“恢复 QQ 本地图片”。"; healthy["qq"] = false
            }
            due["qq"] = Date().addingTimeInterval(60); refresh()
        }
    }
}
