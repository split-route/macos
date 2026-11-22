// Draws the disk image window background: swift background.swift <out.tiff>
// One drawing at 1x and 2x, combined into a HiDPI TIFF that Finder picks per display.
import AppKit

let size = NSSize(width: 560, height: 320) // window content size in points; keep in sync with dmg-settings.py
// Icon centers, from the top. The icon (112pt) plus its label is centered vertically.
let appX: CGFloat = 150, appsX: CGFloat = 410, iconY: CGFloat = 142

func draw() {
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    let flip = { (y: CGFloat) in size.height - y }

    // Wordmark, top left.
    let mark = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))!
    let tint = NSImage(size: mark.size, flipped: false) { r in
        mark.draw(in: r)
        NSColor.black.set()
        r.fill(using: .sourceAtop)
        return true
    }
    tint.draw(in: NSRect(x: 24, y: flip(38), width: mark.size.width, height: mark.size.height))
    ("Splitroute" as NSString).draw(at: NSPoint(x: 28 + mark.size.width, y: flip(39)), withAttributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.black,
    ])

    // A route that leaves the app and turns into Applications: dashed line, arrowhead.
    let y = flip(iconY)
    let from = appX + 80, to = appsX - 80
    let blue = NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)
    blue.setStroke()
    let line = NSBezierPath()
    line.move(to: NSPoint(x: from, y: y))
    line.line(to: NSPoint(x: to - 6, y: y))
    line.lineWidth = 3
    line.lineCapStyle = .round
    line.setLineDash([0.1, 9], count: 2, phase: 0)
    line.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: to - 12, y: y + 8))
    head.line(to: NSPoint(x: to, y: y))
    head.line(to: NSPoint(x: to - 12, y: y - 8))
    head.lineWidth = 3
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // Help line under the icon labels, clear of the bottom edge: Finder's path
    // and status bars, when the user has them on, cover the last ~88 pt.
    let help = "Drag Splitroute to Applications to install" as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
    let w = help.size(withAttributes: attrs).width
    help.draw(at: NSPoint(x: (size.width - w) / 2, y: flip(272)), withAttributes: attrs)
}

func png(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance(draw)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dir = out.deletingLastPathComponent()
let p1 = dir.appendingPathComponent("bg.png"), p2 = dir.appendingPathComponent("bg@2x.png")
try png(scale: 1).write(to: p1)
try png(scale: 2).write(to: p2)
let t = Process()
t.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
t.arguments = ["-cathidpicheck", p1.path, p2.path, "-out", out.path]
try t.run()
t.waitUntilExit()
try? FileManager.default.removeItem(at: p1)
try? FileManager.default.removeItem(at: p2)
exit(t.terminationStatus)
