import AppKit

// Draws the DMG window background at 1x and 2x: dark gradient, soft brand glow,
// a dashed arrow from the app slot to the Applications slot, and an install hint.
// Layout must match Scripts/dmg-settings.py (window 660x420, icons at y=190, x=170 / 490).

let size = NSSize(width: 660, height: 420)
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func render(scale: CGFloat) -> Data? {
    let pixels = NSSize(width: size.width * scale, height: size.height * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pixels.width),
        pixelsHigh: Int(pixels.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let bounds = NSRect(origin: .zero, size: size)
    NSGradient(colors: [
        NSColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1),
        NSColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1)
    ])?.draw(in: bounds, angle: -90)

    let glow = NSGradient(colors: [
        NSColor(red: 0.20, green: 0.48, blue: 0.98, alpha: 0.28),
        NSColor(red: 0.20, green: 0.48, blue: 0.98, alpha: 0)
    ])
    glow?.draw(fromCenter: NSPoint(x: 330, y: 250), radius: 0, toCenter: NSPoint(x: 330, y: 250), radius: 300, options: [])

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: 232))
    arrow.curve(to: NSPoint(x: 398, y: 232), controlPoint1: NSPoint(x: 300, y: 268), controlPoint2: NSPoint(x: 360, y: 268))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.setLineDash([2, 9], count: 2, phase: 0)
    NSColor.white.withAlphaComponent(0.55).setStroke()
    arrow.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: 386, y: 246))
    head.line(to: NSPoint(x: 400, y: 231))
    head.line(to: NSPoint(x: 381, y: 226))
    head.lineWidth = 3
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let title = NSAttributedString(string: "Drag Lumora to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        .paragraphStyle: paragraph
    ])
    title.draw(in: NSRect(x: 0, y: 84, width: size.width, height: 24))
    let subtitle = NSAttributedString(string: "Then open it from Launchpad or your Applications folder.", attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        .paragraphStyle: paragraph
    ])
    subtitle.draw(in: NSRect(x: 0, y: 62, width: size.width, height: 18))

    let firstLaunch = NSAttributedString(
        string: "First launch: System Settings → Privacy & Security → Open Anyway",
        attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(red: 0.55, green: 0.72, blue: 1, alpha: 0.85),
            .paragraphStyle: paragraph
        ]
    )
    firstLaunch.draw(in: NSRect(x: 0, y: 24, width: size.width, height: 16))

    return rep.representation(using: .png, properties: [:])
}

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    guard let data = render(scale: scale) else {
        FileHandle.standardError.write("failed to render \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}
