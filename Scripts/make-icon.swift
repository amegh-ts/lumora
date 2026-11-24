import AppKit

let output = CommandLine.arguments.dropFirst().first ?? ".build/Lumora.iconset"
let directory = URL(fileURLWithPath: output, isDirectory: true)
try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

let entries: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in entries {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    bounds.fill()

    let inset = size * 0.06
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
    let colors = [
        NSColor(red: 0.20, green: 0.48, blue: 0.98, alpha: 1),
        NSColor(red: 0.08, green: 0.20, blue: 0.60, alpha: 1)
    ]
    if let gradient = NSGradient(colors: colors) {
        gradient.draw(in: path, angle: -90)
    }

    NSColor.white.withAlphaComponent(0.94).setFill()
    let triangle = NSBezierPath()
    triangle.move(to: NSPoint(x: size * 0.41, y: size * 0.66))
    triangle.line(to: NSPoint(x: size * 0.70, y: size * 0.50))
    triangle.line(to: NSPoint(x: size * 0.41, y: size * 0.34))
    triangle.close()
    triangle.fill()
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: directory.appendingPathComponent(name))
}
