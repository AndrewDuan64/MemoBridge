import AppKit
import CoreGraphics
import Foundation

// Regenerate the bundled app icon using the macOS SDK.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconFile = URL(fileURLWithPath: CommandLine.arguments[2])
var encoded: [String: Data] = [:]
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, pixels) in sizes {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon image") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let background = CGRect(x: 92, y: 92, width: 840, height: 840)
    let shape = CGPath(roundedRect: background, cornerWidth: 205, cornerHeight: 205, transform: nil)
    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    let colors = [NSColor(calibratedRed: 0.14, green: 0.29, blue: 0.78, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.08, green: 0.60, blue: 0.76, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 170, y: 910), end: CGPoint(x: 840, y: 110), options: [])
    cg.restoreGState()
    cg.addPath(shape)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
    cg.setLineWidth(4)
    cg.strokePath()
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.setLineWidth(42)
    cg.setLineCap(.round)
    // A voice waveform flowing into three lines of text.
    for (x, height) in [(244, 94), (315, 230), (386, 346), (457, 240), (528, 122)] {
        cg.move(to: CGPoint(x: x, y: 512 - height / 2))
        cg.addLine(to: CGPoint(x: x, y: 512 + height / 2))
    }
    cg.strokePath()
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.90).cgColor)
    for (y, width) in [(605, 188), (512, 158), (419, 188)] {
        cg.move(to: CGPoint(x: 629, y: y))
        cg.addLine(to: CGPoint(x: 629 + width, y: y))
    }
    cg.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
    try data.write(to: output.appendingPathComponent(name), options: .atomic)
    encoded[name] = data
}
let types: [(String, String)] = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png")
]
func lengthBytes(_ count: Int) -> Data {
    var value = UInt32(count).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
var sections = Data()
for (type, name) in types {
    let image = encoded[name]!
    sections.append(Data(type.utf8))
    sections.append(lengthBytes(image.count + 8))
    sections.append(image)
}
var icon = Data("icns".utf8)
icon.append(lengthBytes(sections.count + 8))
icon.append(sections)
try icon.write(to: iconFile, options: .atomic)
