// Dessine l'icône de Zeste (1024 px) : une roue à six parts sur fond violet, création originale.
// Usage : swift scripts/make-icon.swift sortie.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Fond : carré arrondi façon macOS, dégradé violet.
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.36, green: 0.17, blue: 0.85, alpha: 1), NSColor(red: 0.60, green: 0.42, blue: 0.98, alpha: 1)])!
    .draw(in: bg, angle: 90)

// Roue : six parts, une mise en avant.
let c = NSPoint(x: size / 2, y: size / 2)
let rOut: CGFloat = 300, rIn: CGFloat = 118
for i in 0..<6 {
    let start = 90 - CGFloat(i) * 60 + 26, end = 90 - CGFloat(i) * 60 - 26
    let p = NSBezierPath()
    p.appendArc(withCenter: c, radius: rOut, startAngle: start, endAngle: end, clockwise: true)
    p.appendArc(withCenter: c, radius: rIn, startAngle: end, endAngle: start, clockwise: false)
    p.close()
    (i == 0 ? NSColor.white : NSColor(white: 1, alpha: 0.42)).setFill()
    p.fill()
}
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: c.x - 62, y: c.y - 62, width: 124, height: 124)).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
