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

struct Settings: Codable, Sendable {
    var schemaVersion = 2
    var wechat: Configuration
    var qq: Configuration
    init(wechat: Configuration = Configuration(), qq: Configuration = .qqDefault) {
        self.wechat = wechat; self.qq = qq
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
    init() throws {
        try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        descriptor = open(AppPaths.support.appendingPathComponent("qq-operation.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw failure("无法创建 QQ 操作锁。") }
        guard lockf(descriptor, F_TLOCK, 0) == 0 else {
            close(descriptor); descriptor = -1
            throw failure("另一项 QQ 迁移或恢复仍在运行，请稍后重试。")
        }
    }
    func release() { if descriptor >= 0 { _ = lockf(descriptor, F_ULOCK, 0); close(descriptor); descriptor = -1 } }
    deinit { release() }
}
