// Draws the disk image window background: swift background.swift <out.tiff>
// One drawing at 1x and 2x, combined into a HiDPI TIFF that Finder picks per display.
import AppKit

let size = NSSize(width: 560, height: 320) // window content size in points; keep in sync with dmg-settings.py
// Icon centers, from the top. The icon (112pt) plus its label is centered vertically.
let appX: CGFloat = 150, appsX: CGFloat = 410, iconY: CGFloat = 142

func draw() {
    let rect = NSRect(origin: .zero, size: size)
    let flip = { (y: CGFloat) in size.height - y }
    let blue = NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)

    // Sky: pale blue at the top left into lavender at the bottom right.
    NSGradient(colors: [
        NSColor(srgbRed: 0.87, green: 0.92, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.74, green: 0.80, blue: 1.00, alpha: 1),
    ])!.draw(in: rect, angle: -35)

    // Two soft waves, like the glass in the app: a milky fill with a bright edge along the crest.
    func wave(_ pts: [(CGFloat, CGFloat)], fill: NSColor, edge: NSColor) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: pts[0].0, y: flip(pts[0].1)))
        p.curve(to: NSPoint(x: pts[3].0, y: flip(pts[3].1)),
                controlPoint1: NSPoint(x: pts[1].0, y: flip(pts[1].1)), controlPoint2: NSPoint(x: pts[2].0, y: flip(pts[2].1)))
        let crest = p.copy() as! NSBezierPath
        p.line(to: NSPoint(x: size.width, y: 0))
        p.line(to: NSPoint(x: 0, y: 0))
        p.close()
        fill.setFill(); p.fill()
        edge.setStroke(); crest.lineWidth = 1.5; crest.stroke()
    }
    wave([(0, 205), (150, 130), (330, 290), (560, 175)],
         fill: NSColor.white.withAlphaComponent(0.34), edge: NSColor.white.withAlphaComponent(0.75))
    wave([(0, 262), (190, 205), (360, 335), (560, 245)],
         fill: NSColor(srgbRed: 0.42, green: 0.55, blue: 1, alpha: 0.20), edge: NSColor.white.withAlphaComponent(0.5))

    // A glow at the top right, behind the watermark.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 490, y: flip(46)), radius: 0, toCenter: NSPoint(x: 490, y: flip(46)), radius: 150, options: [])

    // The branch, large and faint, top right.
    func symbol(_ pt: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSImage {
        let img = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: pt, weight: weight))!
        return NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r); color.set(); r.fill(using: .sourceAtop); return true
        }
    }
    let big = symbol(110, .semibold, NSColor.white)
    big.draw(in: NSRect(x: size.width - 24 - big.size.width, y: size.height - 14 - big.size.height, width: big.size.width, height: big.size.height),
             from: .zero, operation: .sourceOver, fraction: 0.42)

    // Title block, top left: the mark, the name, what to do.
    let mark = symbol(22, .bold, NSColor.black)
    mark.draw(in: NSRect(x: 26, y: flip(58), width: mark.size.width, height: mark.size.height))
    ("Splitroute" as NSString).draw(at: NSPoint(x: 62, y: flip(46)), withAttributes: [
        .font: NSFont.systemFont(ofSize: 21, weight: .bold), .foregroundColor: NSColor.black,
    ])
    ("Drag and drop to install" as NSString).draw(at: NSPoint(x: 62, y: flip(66)), withAttributes: [
        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(srgbRed: 0.33, green: 0.38, blue: 0.52, alpha: 1),
    ])

    // The route: dots from the app to Applications, ending in an arrowhead.
    let y = flip(iconY - 8)
    let from = appX + 78, to = appsX - 78
    blue.setStroke()
    let line = NSBezierPath()
    line.move(to: NSPoint(x: from, y: y))
    line.line(to: NSPoint(x: to - 8, y: y))
    line.lineWidth = 3
    line.lineCapStyle = .round
    line.setLineDash([0.1, 9], count: 2, phase: 0)
    line.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: to - 13, y: y + 9))
    head.line(to: NSPoint(x: to, y: y))
    head.line(to: NSPoint(x: to - 13, y: y - 9))
    head.lineWidth = 3
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()
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
