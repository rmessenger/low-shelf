import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        NSColor(calibratedRed: 0.07, green: 0.11, blue: 0.09, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210).fill()
        NSColor(calibratedRed: 0.65, green: 0.91, blue: 0.62, alpha: 1).setStroke()
        let shelf = NSBezierPath()
        shelf.lineWidth = 48
        shelf.lineCapStyle = .round
        shelf.move(to: NSPoint(x: 220, y: 680))
        shelf.line(to: NSPoint(x: 320, y: 680))
        shelf.curve(to: NSPoint(x: 700, y: 370), controlPoint1: NSPoint(x: 530, y: 680), controlPoint2: NSPoint(x: 460, y: 370))
        shelf.line(to: NSPoint(x: 804, y: 370))
        shelf.stroke()
        NSColor.white.withAlphaComponent(0.13).setStroke()
        let baseline = NSBezierPath()
        baseline.lineWidth = 12
        baseline.lineCapStyle = .round
        baseline.move(to: NSPoint(x: 220, y: 260))
        baseline.line(to: NSPoint(x: 804, y: 260))
        baseline.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
