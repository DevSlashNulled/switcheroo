import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let side = CGFloat(pixels)
        let background = NSBezierPath(roundedRect: NSRect(x: side * 0.07, y: side * 0.07,
            width: side * 0.86, height: side * 0.86), xRadius: side * 0.2, yRadius: side * 0.2)
        NSColor(calibratedRed: 0.22, green: 0.32, blue: 0.88, alpha: 1).setFill()
        background.fill()
        let arrows = NSBezierPath()
        arrows.lineWidth = side * 0.07
        arrows.lineCapStyle = .round
        arrows.lineJoinStyle = .round
        arrows.move(to: NSPoint(x: side * 0.26, y: side * 0.64))
        arrows.line(to: NSPoint(x: side * 0.74, y: side * 0.64))
        arrows.move(to: NSPoint(x: side * 0.61, y: side * 0.77))
        arrows.line(to: NSPoint(x: side * 0.74, y: side * 0.64))
        arrows.line(to: NSPoint(x: side * 0.61, y: side * 0.51))
        arrows.move(to: NSPoint(x: side * 0.74, y: side * 0.36))
        arrows.line(to: NSPoint(x: side * 0.26, y: side * 0.36))
        arrows.move(to: NSPoint(x: side * 0.39, y: side * 0.49))
        arrows.line(to: NSPoint(x: side * 0.26, y: side * 0.36))
        arrows.line(to: NSPoint(x: side * 0.39, y: side * 0.23))
        NSColor.white.setStroke()
        arrows.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
    }
}
