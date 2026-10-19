// Package the transparent Moyuu NAS mascot into standard macOS icon sizes.
import AppKit
import Foundation
let target = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
func render(_ pixels: Int) throws -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Support/AppIcon.png")
    guard let image = NSImage(contentsOf: source) else { fatalError("Missing application icon") }
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    return rep.representation(using:.png,properties:[:])!
}
for size in [16,32,128,256,512] {
    try render(size).write(to: target.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size*2).write(to: target.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
