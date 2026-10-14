// Draws the app icon and writes MediaHelper/Resources/AppIcon.icns.
//   swiftc -O -o /tmp/make-icon scripts/make-icon.swift && /tmp/make-icon
import AppKit

func draw(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Rounded tile (macOS icon grid: art fills ~80% of the canvas).
    let inset = s * 0.1
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = tile.width * 0.225
    let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor(calibratedRed: 0.20, green: 0.35, blue: 0.85, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [NSColor(calibratedRed: 0.36, green: 0.55, blue: 1.0, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.38, green: 0.25, blue: 0.85, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    ctx.restoreGState()

    // Play triangle (video) ...
    let white = NSColor.white
    ctx.setFillColor(white.cgColor)
    let cx = tile.midX - tile.width * 0.07, cy = tile.midY + tile.height * 0.05
    let h = tile.height * 0.40, w = h * 0.88
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: cx - w * 0.38, y: cy + h / 2))
    tri.addLine(to: CGPoint(x: cx - w * 0.38, y: cy - h / 2))
    tri.addLine(to: CGPoint(x: cx + w * 0.62, y: cy))
    tri.closeSubpath()
    ctx.setLineJoin(.round); ctx.setLineWidth(tile.width * 0.05)
    ctx.setStrokeColor(white.cgColor)
    ctx.addPath(tri); ctx.drawPath(using: .fillStroke)

    // ... and a music note (audio) in the lower right.
    let nx = tile.midX + tile.width * 0.18, ny = tile.minY + tile.height * 0.22
    let nw = tile.width * 0.075
    ctx.setFillColor(white.cgColor)
    ctx.fillEllipse(in: CGRect(x: nx - nw * 1.6, y: ny - nw * 0.9, width: nw * 2.1, height: nw * 1.6))
    ctx.fillEllipse(in: CGRect(x: nx + nw * 1.6, y: ny - nw * 1.5, width: nw * 2.1, height: nw * 1.6))
    ctx.fill(CGRect(x: nx + nw * 0.25, y: ny, width: nw * 0.5, height: tile.height * 0.22))
    ctx.fill(CGRect(x: nx + nw * 3.15, y: ny - nw * 0.6, width: nw * 0.5, height: tile.height * 0.22))
    let beam = CGMutablePath()
    beam.move(to: CGPoint(x: nx + nw * 0.25, y: ny + tile.height * 0.22))
    beam.addLine(to: CGPoint(x: nx + nw * 3.65, y: ny - nw * 0.6 + tile.height * 0.22))
    beam.addLine(to: CGPoint(x: nx + nw * 3.65, y: ny - nw * 0.6 + tile.height * 0.22 - nw * 0.9))
    beam.addLine(to: CGPoint(x: nx + nw * 0.25, y: ny + tile.height * 0.22 - nw * 0.9))
    beam.closeSubpath()
    ctx.addPath(beam); ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("MediaHelper.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let png = draw(size: px).representation(using: .png, properties: [:])!
    try png.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let out = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("MediaHelper/Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
// also a preview PNG for the docs
try draw(size: 512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("docs/icon-preview.png"))
