// Run with: swift scripts/test.swift
// Compile the production services without launching the AppKit event loop.
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("WeChatNASMount-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let source = try String(contentsOf: root.appendingPathComponent("Sources/WeChatNASMount/main.swift"), encoding: .utf8)
let services = String(source.components(separatedBy: "@MainActor\nfinal class AppDelegate")[0])
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
