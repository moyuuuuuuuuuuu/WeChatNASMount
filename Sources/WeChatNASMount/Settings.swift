import Foundation

func failure(_ message: String) -> NSError {
    NSError(domain: "WeChatNASMount", code: 10, userInfo: [NSLocalizedDescriptionKey: message])
}

extension Configuration {
    static var qqDefault: Configuration {
        Configuration(enabled: false, remoteDirectory: "QQ", mountPoint: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.tencent.qq/Data/Documents/nas-qq-storage").path)
    }
    var remoteRoot: URL {
        URL(fileURLWithPath: mountPoint).appendingPathComponent(remoteDirectory, isDirectory: true).standardizedFileURL
    }
    func validate(forQQ: Bool) throws {
        guard !server.isEmpty, !share.isEmpty, !username.isEmpty else { throw failure("请填写 NAS 地址、共享名和用户名。") }
        for value in [server, fallbackServer, username, share] {
            guard !value.contains(where: { "/\\@:%\n\r\t".contains($0) }) else {
                throw failure("地址、共享名或用户名包含不支持的字符。地址只填写主机名或 IPv4 地址。")
            }
        }
        guard !remoteDirectory.hasPrefix("/"), !remoteDirectory.contains("\\"),
              !remoteDirectory.contains(where: { $0.isNewline || $0 == "\0" }),
              !remoteDirectory.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." }) else {
            throw failure("远端目录请填写共享内的相对路径，不能包含 . 或 ..。")
        }
        guard mountPoint.hasPrefix("/"), URL(fileURLWithPath: mountPoint).standardizedFileURL.path == mountPoint else {
            throw failure("挂载点必须是规范的绝对路径。")
        }
        if forQQ && mountPoint != Configuration.qqDefault.mountPoint {
            throw failure("QQ 必须使用其沙盒内的固定挂载点。")
        }
    }
}

struct NASConnection: Codable, Sendable, Equatable {
    var server: String
    var fallbackServer: String
    var username: String
    init(_ config: Configuration = Configuration()) {
        server = config.server; fallbackServer = config.fallbackServer; username = config.username
    }
    func applying(to config: Configuration) -> Configuration {
        var value = config
        value.server = server; value.fallbackServer = fallbackServer; value.username = username
        return value
    }
}

extension Configuration {
    static var feishuDefault: Configuration {
        Configuration(enabled: false, remoteDirectory: "Feishu", mountPoint: AppPaths.support.appendingPathComponent("mounts/feishu").path)
    }
}

struct Settings: Codable, Sendable {
    var schemaVersion = 3
    var connection: NASConnection
    var wechat: Configuration
    var qq: Configuration
    var feishu: Configuration
    init(wechat: Configuration = Configuration(), qq: Configuration = .qqDefault,
         feishu: Configuration = .feishuDefault, connection: NASConnection? = nil) {
        let profiles = [wechat, qq, feishu]
        let primary = profiles.first { $0.enabled && !$0.server.isEmpty } ?? profiles.first { !$0.server.isEmpty } ?? wechat
        let shared = connection ?? NASConnection(primary)
        self.connection = shared
        self.wechat = shared.applying(to: wechat); self.qq = shared.applying(to: qq); self.feishu = shared.applying(to: feishu)
    }
    enum CodingKeys: String, CodingKey { case schemaVersion, connection, wechat, qq, feishu }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let w = try values.decode(Configuration.self, forKey: .wechat)
        let q = try values.decodeIfPresent(Configuration.self, forKey: .qq) ?? .qqDefault
        let f = try values.decodeIfPresent(Configuration.self, forKey: .feishu) ?? .feishuDefault
        let shared = try values.decodeIfPresent(NASConnection.self, forKey: .connection)
        let active = [w, q, f].filter { $0.enabled && !$0.server.isEmpty }
        // Reject ambiguous old settings rather than redirecting migrated links to another NAS.
        if shared == nil, let first = active.first,
           active.contains(where: { NASConnection($0) != NASConnection(first) }) {
            throw failure("旧配置使用了不同 NAS 连接，请先统一主地址、备用地址和用户名后再升级。原配置未改动。")
        }
        self.init(wechat: w, qq: q, feishu: f, connection: shared)
    }
}

enum SettingsStore {
    static func decode(_ data: Data) throws -> Settings {
        let decoder = JSONDecoder()
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if object?["wechat"] != nil { return try decoder.decode(Settings.self, from: data) }
        return Settings(wechat: try decoder.decode(Configuration.self, from: data))
    }
    static func read() throws -> Settings {
        guard FileManager.default.fileExists(atPath: AppPaths.config.path) else { return Settings() }
        return try decode(Data(contentsOf: AppPaths.config))
    }
    // UI handles decode failures explicitly; never silently overwrite a broken config.
    static func load() -> Settings { (try? read()) ?? Settings() }
    static func encoded(_ value: Settings) throws -> Data {
        let encoder = JSONEncoder()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(value)) as! [String: Any]
        let legacy = try JSONSerialization.jsonObject(with: encoder.encode(value.wechat)) as! [String: Any]
        object.merge(legacy) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
    static func save(_ value: Settings) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        if fm.fileExists(atPath: AppPaths.config.path) {
            _ = try read()
            try fm.copyItem(at: AppPaths.config, to: AppPaths.support.appendingPathComponent("config-backup-\(UUID().uuidString).json"))
        }
        // Keep the legacy top-level WeChat fields so the installed 0.3.x helper
        // can still read its configuration during an upgrade or rollback.
        try encoded(value).write(to: AppPaths.config, options: .atomic)
    }
}

enum CommandRunner {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) throws -> (Int32, String) {
        let process = Process()
        // A file avoids pipe-buffer deadlocks while the parent enforces its deadline.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nas-command-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close(); try? FileManager.default.removeItem(at: url) }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.standardOutput = output; process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw failure("检查超时，NAS 可能离线；保留现有链接和本地备份，稍后自动重试。")
        }
        let data = try Data(contentsOf: url)
        return (process.terminationStatus, String(decoding: data.prefix(65536), as: UTF8.self))
    }
    static func worker(_ arguments: [String], timeout: TimeInterval = 55) throws -> String {
        let result = try run(CommandLine.arguments[0], arguments, timeout: timeout)
        guard result.0 == 0 else { throw failure(result.1.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return result.1.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// A timed-out worker may still be exiting a kernel filesystem call. Its lock prevents
// another process from restoring or migrating the same directories concurrently.
final class QQMutationLock {
    private var descriptor: Int32 = -1
    init(name: String = "qq") throws {
        guard ["qq", "feishu"].contains(name) else { throw failure("未知操作锁。") }
        try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        descriptor = open(AppPaths.support.appendingPathComponent("\(name)-operation.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw failure("无法创建 QQ 操作锁。") }
        guard lockf(descriptor, F_TLOCK, 0) == 0 else {
            close(descriptor); descriptor = -1
            throw failure("另一项图片迁移或恢复仍在运行，请稍后重试。")
        }
    }
    func release() { if descriptor >= 0 { _ = lockf(descriptor, F_ULOCK, 0); close(descriptor); descriptor = -1 } }
    deinit { release() }
}
