// Draws the Spool app icon (a generic thread spool) into an .iconset directory.
// Usage: swift scripts/make-icon.swift <output.iconset>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Draws on a 1024-unit canvas; the caller scales the context.
func draw(_ c: CGContext) {
    // macOS icon grid: 824 square centred on 1024, corner radius about 185.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    c.addPath(roundedRect(tile, 185)); c.setFillColor(rgb(0xECEAE5)); c.fillPath()

    let ink = rgb(0x2B2B2D)
    let mid = rgb(0x48484B)
    // Core (the barrel the thread winds on).
    let core = CGRect(x: 392, y: 300, width: 240, height: 424)
    c.addPath(roundedRect(core, 24)); c.setFillColor(mid); c.fillPath()
    // Amber thread band wound around the core.
    let band = CGRect(x: 372, y: 400, width: 280, height: 224)
    c.addPath(roundedRect(band, 36)); c.setFillColor(rgb(0xC98500)); c.fillPath()
    // Thread winding lines.
    c.setStrokeColor(rgb(0x9A6500)); c.setLineWidth(6)
    for i in 1..<5 {
        let y = band.minY + CGFloat(i) * band.height / 5
        c.move(to: CGPoint(x: band.minX + 8, y: y)); c.addLine(to: CGPoint(x: band.maxX - 8, y: y))
    }
    c.strokePath()
    // Flanges.
    c.addPath(roundedRect(CGRect(x: 292, y: 224, width: 440, height: 88), 36))
    c.setFillColor(ink); c.fillPath()
    c.addPath(roundedRect(CGRect(x: 292, y: 712, width: 440, height: 88), 36))
    c.setFillColor(ink); c.fillPath()
}

func writePNG(size: Int, to url: URL) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(ctx)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(size: base, to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(size: base * 2, to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
