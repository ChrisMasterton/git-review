import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func image(size: Int) -> NSImage {
    let side = CGFloat(size)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }

    let inset = side * 0.06
    let shell = NSBezierPath(
        roundedRect: NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2),
        xRadius: side * 0.21,
        yRadius: side * 0.21
    )
    NSGradient(colors: [
        NSColor(calibratedRed: 0.035, green: 0.075, blue: 0.105, alpha: 1),
        NSColor(calibratedRed: 0.035, green: 0.22, blue: 0.26, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.39, blue: 0.38, alpha: 1)
    ])?.draw(in: shell, angle: -45)

    let line = NSBezierPath()
    line.move(to: NSPoint(x: side * 0.34, y: side * 0.73))
    line.line(to: NSPoint(x: side * 0.34, y: side * 0.28))
    line.move(to: NSPoint(x: side * 0.34, y: side * 0.55))
    line.curve(
        to: NSPoint(x: side * 0.68, y: side * 0.42),
        controlPoint1: NSPoint(x: side * 0.52, y: side * 0.55),
        controlPoint2: NSPoint(x: side * 0.52, y: side * 0.42)
    )
    line.lineWidth = max(2, side * 0.055)
    line.lineCapStyle = .round
    line.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.92).setStroke()
    line.stroke()

    for point in [
        NSPoint(x: side * 0.34, y: side * 0.73),
        NSPoint(x: side * 0.34, y: side * 0.28),
        NSPoint(x: side * 0.68, y: side * 0.42)
    ] {
        let radius = side * 0.075
        let node = NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        NSColor(calibratedRed: 0.34, green: 1, blue: 0.51, alpha: 1).setFill()
        node.fill()
        node.lineWidth = max(1, side * 0.018)
        NSColor.white.withAlphaComponent(0.8).setStroke()
        node.stroke()
    }
    return image
}

let outputs: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]

for (size, name) in outputs {
    guard let tiff = image(size: size).tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: destination.appendingPathComponent(name))
}
