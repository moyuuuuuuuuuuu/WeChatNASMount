// Run with: swift scripts/test.swift
// Compile the production services without launching the AppKit event loop.
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("WeChatNASMount-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let source = try String(contentsOf: root.appendingPathComponent("Sources/WeChatNASMount/main.swift"), encoding: .utf8)
let services = String(source.components(separatedBy: "// Worker processes")[0]) + "\n" + (try String(contentsOf: root.appendingPathComponent("Sources/WeChatNASMount/Settings.swift"), encoding: .utf8)) + "\n" + (try String(contentsOf: root.appendingPathComponent("Sources/WeChatNASMount/QQService.swift"), encoding: .utf8))
let tests = #"""
let fm = FileManager.default
let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
let mount = fixture.appendingPathComponent("nas")
let local = fixture.appendingPathComponent("xwechat_files/account/msg")
let remote = mount.appendingPathComponent("xwechat_files/account/msg")
try fm.createDirectory(at: local, withIntermediateDirectories: true)
try fm.createDirectory(at: remote, withIntermediateDirectories: true)
let config = Configuration(server: "primary", fallbackServer: "fallback", share: "share", username: "user", mountPoint: mount.path)
func check(_ condition: Bool, _ name: String) {
    guard condition else { fatalError("FAIL: \(name)") }
    print("PASS: \(name)")
}
check(MountService.matchesMount("//user@primary/share on \(mount.path) (smbfs, noowners)", config), "primary SMB mount")
check(MountService.matchesMount("//user@fallback/share on \(mount.path) (smbfs, noowners)", config), "fallback SMB mount")
var encodedConfig = config
encodedConfig.share = "聊天 存储"
check(MountService.matchesMount("//user@primary/%E8%81%8A%E5%A4%A9%20%E5%AD%98%E5%82%A8 on \(mount.path) (smbfs, noowners)", encodedConfig), "encoded Unicode share mount")
check(!MountService.matchesMount("//user@primary/other on \(mount.path) (smbfs, noowners)", config), "reject wrong share")
check(!MountService.matchesMount("//user@primary/share on \(mount.path) (apfs, local)", config), "reject local directory")
for name in ["attach", "video", "file"] {
    let target = remote.appendingPathComponent(name)
    try fm.createDirectory(at: target, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: local.appendingPathComponent(name), withDestinationURL: target)
}
check(try MountService.verifyMedia(config) == 3, "three readable NAS media links")
try fm.removeItem(at: remote.appendingPathComponent("video"))
var rejected = false
do { _ = try MountService.verifyMedia(config) } catch { rejected = true }
check(rejected, "reject dangling media link")
try fm.removeItem(at: local.appendingPathComponent("video"))
rejected = false
do { _ = try MountService.verifyMedia(config) } catch { rejected = true }
check(rejected, "reject missing media link")
try fm.createSymbolicLink(at: local.appendingPathComponent("video"), withDestinationURL: fixture)
rejected = false
do { _ = try MountService.verifyMedia(config) } catch { rejected = true }
check(rejected, "reject link outside NAS")
// Legacy settings must retain every WeChat path and leave QQ off.
let legacy = Data(#"{"server":"primary","share":"share","username":"user","mountPoint":"/legacy/wechat"}"#.utf8)
let upgraded = try SettingsStore.decode(legacy)
check(upgraded.wechat.mountPoint == "/legacy/wechat" && upgraded.wechat.enabled, "legacy WeChat settings preserved")
let legacyReader = try JSONDecoder().decode(Configuration.self, from: SettingsStore.encoded(upgraded))
check(legacyReader.mountPoint == "/legacy/wechat" && legacyReader.server == "primary", "saved config remains readable by old WeChat client")
check(!upgraded.qq.enabled && upgraded.qq.remoteDirectory == "QQ", "QQ defaults disabled with independent remote folder")
check(try SettingsStore.decode(JSONEncoder().encode(upgraded)).wechat.mountPoint == "/legacy/wechat", "settings v2 round trip")
var invalid = Configuration.qqDefault
invalid.server = "nas"; invalid.share = "share"; invalid.username = "user"; invalid.remoteDirectory = "../wechat"
rejected = false
do { try invalid.validate(forQQ: true) } catch { rejected = true }
check(rejected, "reject remote traversal")
invalid.remoteDirectory = "QQ"; invalid.mountPoint = "/Volumes/share"
rejected = false
do { try invalid.validate(forQQ: true) } catch { rejected = true }
check(rejected, "reject QQ mount outside sandbox")
let original = fixture.appendingPathComponent("qq/Pic")
let destination = fixture.appendingPathComponent("nas/QQ/account/Pic")
try fm.createDirectory(at: original, withIntermediateDirectories: true)
try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("image fixture".utf8).write(to: original.appendingPathComponent("image.bin"))
let journalURL = fixture.appendingPathComponent("journal.json")
var entries: [QQMigration] = []
try QQService.migrateDirectory(source: original, destination: destination, entries: &entries, journalURL: journalURL)
check(try fm.destinationOfSymbolicLink(atPath: original.path) == destination.path, "QQ migration installs NAS link")
check(try QQService.manifest(destination) == QQService.manifest(URL(fileURLWithPath: entries[0].backup)), "QQ verified local backup retained")
try Data("new image on NAS".utf8).write(to: destination.appendingPathComponent("new.bin"))
// Simulate unavailable NAS without contacting any real network or touching real QQ data.
let offline = destination.deletingLastPathComponent().appendingPathComponent("offline-Pic")
try fm.moveItem(at: destination, to: offline)
try QQService.restore(entries: entries, journalURL: journalURL)
check((try? fm.destinationOfSymbolicLink(atPath: original.path)) == nil, "offline restore replaces dangling link with local directory")
check(try Data(contentsOf: original.appendingPathComponent("image.bin")) == Data("image fixture".utf8), "offline restore preserves original image")
check(fm.fileExists(atPath: offline.appendingPathComponent("new.bin").path), "offline restore retains new NAS data")
// Prepared journal from a crash before rename is safely archived without changing source.
try QQService.write(entries, at: journalURL)
try QQService.restore(entries: entries, journalURL: journalURL)
check(fm.fileExists(atPath: original.appendingPathComponent("image.bin").path), "recover prepared journal idempotently")
let second = fixture.appendingPathComponent("second/Pic")
try fm.createDirectory(at: second, withIntermediateDirectories: true)
try Data("second".utf8).write(to: second.appendingPathComponent("image.bin"))
var interrupted: [QQMigration] = []
rejected = false
do {
    try QQService.migrateDirectory(source: second, destination: fixture.appendingPathComponent("nas/second"), entries: &interrupted,
        journalURL: fixture.appendingPathComponent("interrupted.json"), beforeSwitch: { throw failure("QQ restarted before cutover") })
} catch { rejected = true }
check(rejected && interrupted.isEmpty && fm.fileExists(atPath: second.appendingPathComponent("image.bin").path), "abort before cutover leaves local source unchanged")
rejected = false
do { try QQService.validateJournal([QQMigration(source: "/tmp/Pic", backup: "/tmp/Pic.nas-backup-1", destination: "/tmp/nas")]) } catch { rejected = true }
check(rejected, "reject migration journal outside QQ accounts")
let fakeAccount = QQService.accountRoot.appendingPathComponent("nt_qq_abcd/nt_data/Pic")
try QQService.validateJournal([QQMigration(source: fakeAccount.path, backup: fakeAccount.path + ".nas-backup-test", destination: "/tmp/nas")])
check(true, "accept correctly scoped QQ migration journal")
let malicious = fixture.appendingPathComponent("malicious")
try fm.createDirectory(at: malicious, withIntermediateDirectories: true)
try fm.createSymbolicLink(at: malicious.appendingPathComponent("escape"), withDestinationURL: fixture)
rejected = false
do { _ = try QQService.manifest(malicious) } catch { rejected = true }
check(rejected, "reject symlinks inside cache")
rejected = false
let start = Date()
do { _ = try CommandRunner.run("/bin/sleep", ["10"], timeout: 0.1) } catch { rejected = true }
check(rejected && Date().timeIntervalSince(start) < 3, "bounded network worker timeout")
let permission = NSError(domain: NSCocoaErrorDomain, code: 257)
check(MountService.friendlyError(permission).contains("完全磁盘访问权限"), "permission guidance")
"""#
let testFile = temp.appendingPathComponent("main.swift")
try (services + "\n" + tests).write(to: testFile, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = [testFile.path, temp.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
