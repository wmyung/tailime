import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate-icon.swift <output-iconset-dir>\n", stderr)
    exit(1)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> Data? {
    let size = NSSize(width: pixelSize, height: pixelSize)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(origin: .zero, size: size)
    let inset = CGFloat(pixelSize) * 0.08
    let bgRect = rect.insetBy(dx: inset, dy: inset)
    let radius = bgRect.width * 0.225

    let path = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)
    let grad = NSGradient(
        starting: NSColor(calibratedRed: 0.09, green: 0.14, blue: 0.28, alpha: 1.0),
        ending: NSColor(calibratedRed: 0.14, green: 0.36, blue: 0.72, alpha: 1.0)
    )
    grad?.draw(in: path, angle: -50)

    NSColor.white.withAlphaComponent(0.18).setStroke()
    path.lineWidth = max(1.0, CGFloat(pixelSize) * 0.014)
    path.stroke()

    let mainFont = NSFont.systemFont(ofSize: CGFloat(pixelSize) * 0.34, weight: .bold)
    let subFont = NSFont.monospacedSystemFont(ofSize: CGFloat(pixelSize) * 0.17, weight: .semibold)

    let hanAttrs: [NSAttributedString.Key: Any] = [
        .font: mainFont,
        .foregroundColor: NSColor.white,
    ]
    let hanStr = NSAttributedString(string: "한", attributes: hanAttrs)
    let hanSize = hanStr.size()
    hanStr.draw(at: NSPoint(
        x: bgRect.midX - hanSize.width * 0.52,
        y: bgRect.midY - hanSize.height * 0.16
    ))

    let enAttrs: [NSAttributedString.Key: Any] = [
        .font: subFont,
        .foregroundColor: NSColor(calibratedRed: 0.62, green: 0.90, blue: 1.0, alpha: 0.96),
    ]
    let enStr = NSAttributedString(string: "⇄ EN", attributes: enAttrs)
    let enSize = enStr.size()
    enStr.draw(at: NSPoint(
        x: bgRect.midX - enSize.width / 2.0,
        y: bgRect.minY + bgRect.height * 0.13
    ))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in specs {
    guard let data = renderIcon(pixelSize: px) else {
        fputs("Failed to render \(name)\n", stderr)
        exit(1)
    }
    try data.write(to: outDir.appendingPathComponent(name))
}
