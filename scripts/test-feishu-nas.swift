// Opt-in: swift scripts/test-feishu-nas.swift
// Isolated Feishu image fixtures only; preserves real chat data and existing mounts.
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("feishu-nas-integration-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let main = try String(contentsOf: root.appendingPathComponent("Sources/WeChatNASMount/main.swift"), encoding: .utf8)
var services = String(main.components(separatedBy: "// Worker processes")[0])
for file in ["Settings.swift", "QQService.swift", "FeishuService.swift"] {
    services += "\n" + (try String(contentsOf: root.appendingPathComponent("Sources/WeChatNASMount/" + file), encoding: .utf8))
}
let test = #"""
let fm = FileManager.default
let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let previous = try SettingsStore.read()
let originalConfig = try Data(contentsOf: AppPaths.config)
guard try FeishuService.entries().isEmpty else { throw failure("Skip: real Feishu migration exists") }
var config = Configuration.feishuDefault
config.enabled = true; config.server = previous.connection.server; config.fallbackServer = previous.connection.fallbackServer
config.username = previous.connection.username; config.share = previous.wechat.share
config.remoteDirectory = "feishu-validation-" + UUID().uuidString
if MountService.isMounted(config) { throw failure("Skip: Feishu mount already in use") }
let baselineW = MountService.isMounted(previous.wechat), baselineQ = MountService.isMounted(previous.qq)
let priorMountPathExists = fm.fileExists(atPath: config.mountPoint)
var mounted = false
var createdRemote = false
defer {
    if mounted {
        if createdRemote { try? fm.removeItem(at: config.remoteRoot) }
        _ = try? CommandRunner.run("/sbin/umount", [config.mountPoint])
    }
    if !priorMountPathExists { try? fm.removeItem(atPath: config.mountPoint) }
}
try FeishuService.mount(config); mounted = true
print("PASS: Feishu independent SMB session mounted")
try QQService.ensureRemotePath(config.remoteRoot, mountPoint: config.mountPoint, create: true); createdRemote = true
let accountRoot = fixture.appendingPathComponent("sdk_storage")
let source = accountRoot.appendingPathComponent(String(repeating: "a", count: 32) + "/resources/images")
try fm.createDirectory(at: source, withIntermediateDirectories: true)
try Data("synthetic Feishu cached image".utf8).write(to: source.appendingPathComponent("old.png"))
let journal = fixture.appendingPathComponent("feishu-test-journal.json")
var records: [QQMigration] = []
let destination = config.remoteRoot.appendingPathComponent("images")
try QQService.migrateDirectory(source: source, destination: destination, entries: &records, journalURL: journal)
try FeishuService.validateEntries(records, root: accountRoot)
try checkNAS(try Data(contentsOf: source.appendingPathComponent("old.png")) == Data("synthetic Feishu cached image".utf8), "Feishu NAS image link reads verified data")
try Data("synthetic new NAS image".utf8).write(to: source.appendingPathComponent("new.png"))
print("PASS: Feishu new cache write reaches NAS")
let unmount = try CommandRunner.run("/sbin/umount", [config.mountPoint]); guard unmount.0 == 0 else { throw failure(unmount.1) }; mounted = false
var blocked = false
do { try fm.createDirectory(atPath: config.mountPoint + "/local-fallback", withIntermediateDirectories: true) } catch { blocked = true }
try checkNAS(blocked, "Feishu offline guard blocks local fallback writes")
try FeishuService.restore(records: records, journalURL: journal)
try checkNAS(fm.fileExists(atPath: source.appendingPathComponent("old.png").path), "Feishu offline recovery restores local image")
try checkNAS(fm.fileExists(atPath: records[0].backup + "/old.png"), "Feishu recovery retains original local backup")
try FeishuService.mount(config); mounted = true
try checkNAS(fm.fileExists(atPath: destination.appendingPathComponent("new.png").path), "Feishu reconnect retains new NAS cache")
try checkNAS(try Data(contentsOf: AppPaths.config) == originalConfig, "shared settings unchanged by integration test")
try checkNAS(MountService.isMounted(previous.wechat) == baselineW && MountService.isMounted(previous.qq) == baselineQ, "WeChat and QQ mounts unchanged")
func checkNAS(_ result: Bool, _ name: String) throws {
    guard result else { throw failure(name) }; print("PASS: " + name)
}
"""#
let file = temp.appendingPathComponent("main.swift")
try (services + "\n" + test).write(to: file, atomically: true, encoding: .utf8)
let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/swift"); child.arguments = [file.path, temp.path]
try child.run(); child.waitUntilExit(); exit(child.terminationStatus)
