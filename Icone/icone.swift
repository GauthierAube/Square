// Dessine l'icône de Square (quatre cases) et l'écrit en PNG 1024.
import AppKit
let t = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: t, pixelsHigh: t, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()
let c: CGFloat = 270, e: CGFloat = 44, o = (1024 - 2 * c - e) / 2
let couleurs = [NSColor(srgbRed: 0.847, green: 0.435, blue: 0.290, alpha: 1), NSColor(white: 1, alpha: 0.9),
                NSColor(white: 1, alpha: 0.9), NSColor(white: 1, alpha: 0.9)]
for (i, col) in couleurs.enumerated() {
    col.setFill()
    let x = o + CGFloat(i % 2) * (c + e), y = o + CGFloat(1 - i / 2) * (c + e)
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: c, height: c), xRadius: 56, yRadius: 56).fill()
}
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
