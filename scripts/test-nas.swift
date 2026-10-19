// Opt-in integration test: swift scripts/test-nas.swift
// Uses existing WeChat SMB credentials, isolated synthetic files, and no real QQ account data.
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("qq-nas-integration-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let main = try String(contentsOf: root.appendingPathComponent("Sources/WeChatNASMount/main.swift"), encoding: .utf8)
var services = String(main.components(separatedBy: "// Worker processes")[0])
for file in ["Settings.swift", "QQService.swift"] {
    services += "\n" + (try String(contentsOf: root.appendingPathComponent("Sources/WeChatNASMount/" + file), encoding: .utf8))
}
let test = #"""
let fm = FileManager.default
let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let old = try SettingsStore.read()
guard try QQService.migrations().isEmpty else { throw failure("Skip: real QQ migration exists") }
var config = Configuration.qqDefault
config.enabled = true; config.server = old.wechat.server; config.fallbackServer = old.wechat.fallbackServer
config.username = old.wechat.username; config.share = old.wechat.share
config.remoteDirectory = "qq-validation-" + UUID().uuidString
if MountService.isMounted(config) { throw failure("Skip: QQ mount is already in use") }
let baseline = MountService.isMounted(old.wechat)
var mounted = false
var remoteCreated = false
defer {
    if mounted {
        if remoteCreated { try? fm.removeItem(at: config.remoteRoot) }
        _ = try? CommandRunner.run("/sbin/umount", [config.mountPoint])
    }
    try? fm.removeItem(atPath: config.mountPoint)
}
try QQService.mount(config); mounted = true
print("PASS: real SMB mount inside QQ sandbox")
try QQService.ensureRemotePath(config.remoteRoot, mountPoint: config.mountPoint, create: true); remoteCreated = true
let local = fixture.appendingPathComponent("Pic")
try fm.createDirectory(at: local, withIntermediateDirectories: true)
let bytes = Data("Synthetic QQ NAS image cache fixture".utf8)
try bytes.write(to: local.appendingPathComponent("image.bin"))
var entries: [QQMigration] = []
let journalURL = fixture.appendingPathComponent("test-journal.json")
try QQService.migrateDirectory(source: local, destination: config.remoteRoot.appendingPathComponent("Pic"), entries: &entries, journalURL: journalURL)
guard try Data(contentsOf: local.appendingPathComponent("image.bin")) == bytes else { throw failure("Read mismatch") }
try Data("Synthetic newly cached image".utf8).write(to: local.appendingPathComponent("new.bin"))
print("PASS: verified copy, symlink read and new write on real NAS")
let unmount = try CommandRunner.run("/sbin/umount", [config.mountPoint])
guard unmount.0 == 0 else { throw failure("Cannot unmount test share") }; mounted = false
let mode = try fm.attributesOfItem(atPath: config.mountPoint)[.posixPermissions] as? NSNumber
var blocked = false
do { try fm.createDirectory(atPath: config.mountPoint + "/unexpected-local-data", withIntermediateDirectories: true) } catch { blocked = true }
guard blocked, mode?.intValue == 0o500 else { throw failure("Offline guard failed") }
print("PASS: offline mount point rejects local fallback writes")
try QQService.restore(entries: entries, journalURL: journalURL)
guard try Data(contentsOf: local.appendingPathComponent("image.bin")) == bytes else { throw failure("Offline restoration mismatch") }
print("PASS: restore retained local copy without NAS access")
try QQService.mount(config); mounted = true
_ = try fm.contentsOfDirectory(atPath: config.remoteRoot.path)
guard fm.fileExists(atPath: config.remoteRoot.appendingPathComponent("Pic/new.bin").path) else { throw failure("NAS data lost") }
print("PASS: reconnect after unmount retains new NAS image")
guard MountService.isMounted(old.wechat) == baseline else { throw failure("WeChat mount changed") }
print("PASS: existing WeChat mount unchanged")
"""#
let file = temp.appendingPathComponent("main.swift")
try (services + "\n" + test).write(to: file, atomically: true, encoding: .utf8)
let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/swift"); child.arguments = [file.path, temp.path]
try child.run(); child.waitUntilExit(); exit(child.terminationStatus)
