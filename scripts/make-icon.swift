// Draws ClipStack's app icon and writes Resources/AppIcon.icns.
//   swift scripts/make-icon.swift
// Deterministic: the same script always produces the same artwork, so the icon can be regenerated.
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: the rounded square sits inside a 10% margin.
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2237, yRadius: tile.width * 0.2237)
    NSGradient(starting: NSColor(srgbRed: 0x7B / 255, green: 0x5C / 255, blue: 0xFF / 255, alpha: 1),
               ending: NSColor(srgbRed: 0x4F / 255, green: 0x7C / 255, blue: 0xFF / 255, alpha: 1))!
        .draw(in: tilePath, angle: 90)

    // Three stacked cards, back to front: a clipboard history.
    let cardW = tile.width * 0.54, cardH = tile.width * 0.36
    let step = tile.width * 0.075
    for i in 0..<3 {
        let x = tile.midX - cardW / 2 - step * 0.5 + CGFloat(2 - i) * step * 0.5   // centers the whole stack
        let y = tile.midY - cardH / 2 - step + CGFloat(i) * step
        let card = NSRect(x: x, y: y, width: cardW, height: cardH)
        let path = NSBezierPath(roundedRect: card, xRadius: cardW * 0.09, yRadius: cardW * 0.09)
        NSColor(white: 1, alpha: [0.45, 0.7, 1.0][i]).setFill()
        path.fill()
        if i == 2 {
            // Text lines on the front card.
            NSColor(srgbRed: 0x5A / 255, green: 0x6E / 255, blue: 0xFF / 255, alpha: 0.85).setFill()
            for (n, w) in [0.62, 0.44].enumerated() {
                let line = NSRect(x: card.minX + cardW * 0.14, y: card.maxY - cardH * (0.36 + 0.26 * CGFloat(n)),
                                  width: cardW * w, height: cardH * 0.11)
                NSBezierPath(roundedRect: line, xRadius: line.height / 2, yRadius: line.height / 2).fill()
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
try render(1024).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("ClipStack-icon-preview.png"))
print("Wrote \(out.path)")
