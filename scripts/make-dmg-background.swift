// Fond de la fenêtre d'installation de Zeste.dmg (660 × 420 pt, rendu en 1x et 2x).
// Usage : swift scripts/make-dmg-background.swift <dossier de sortie>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let W: CGFloat = 660, H: CGFloat = 420
// Centres des icônes (repère Finder : origine en haut à gauche) — à garder en phase avec make-dmg.sh.
let appX: CGFloat = 175, appsX: CGFloat = 485, iconY: CGFloat = 200

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let flipY = { (y: CGFloat) in H - y } // dessin AppKit : origine en bas

    // Fond : dégradé violet profond, lisible sous des libellés clairs comme sombres.
    NSGradient(colors: [NSColor(srgbRed: 0.42, green: 0.27, blue: 0.90, alpha: 1),
                        NSColor(srgbRed: 0.30, green: 0.16, blue: 0.70, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -55)

    // Grande roue décorative, très discrète, à droite.
    let c = NSPoint(x: W - 40, y: flipY(330))
    for i in 0..<6 {
        let start = 90 - CGFloat(i) * 60 + 26, end = 90 - CGFloat(i) * 60 - 26
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: 230, startAngle: start, endAngle: end, clockwise: true)
        p.appendArc(withCenter: c, radius: 92, startAngle: end, endAngle: start, clockwise: false)
        p.close()
        NSColor(white: 1, alpha: i == 1 ? 0.10 : 0.045).setFill()
        p.fill()
    }

    // Halos sous les deux icônes.
    for x in [appX, appsX] {
        let r: CGFloat = 78
        NSGradient(colors: [NSColor(white: 1, alpha: 0.16), NSColor(white: 1, alpha: 0)])!
            .draw(in: NSBezierPath(ovalIn: NSRect(x: x - r, y: flipY(iconY) - r, width: r * 2, height: r * 2)), relativeCenterPosition: .zero)
    }

    // Titre et accroche.
    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ alpha: CGFloat, x: CGFloat, y: CGFloat, center: Bool = false) {
        let p = NSMutableParagraphStyle()
        p.alignment = center ? .center : .left
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: NSColor(white: 1, alpha: alpha), .paragraphStyle: p]
        let r = center ? NSRect(x: x - 200, y: flipY(y) - size, width: 400, height: size + 8) : NSRect(x: x, y: flipY(y) - size, width: 500, height: size + 8)
        (s as NSString).draw(in: r, withAttributes: attrs)
    }
    text("Zeste", 30, .heavy, 1, x: 36, y: 34)
    text("Convertis, retouche, partage. D'un simple glisser.", 13, .medium, 0.75, x: 37, y: 74)

    // Flèche pointillée de Zeste vers Applications.
    let arrow = NSBezierPath()
    let y = flipY(iconY - 8)
    arrow.move(to: NSPoint(x: appX + 72, y: y))
    arrow.curve(to: NSPoint(x: appsX - 78, y: y), controlPoint1: NSPoint(x: appX + 140, y: y + 34), controlPoint2: NSPoint(x: appsX - 146, y: y + 34))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.setLineDash([2, 9], count: 2, phase: 0)
    NSColor(white: 1, alpha: 0.85).setStroke()
    arrow.stroke()
    let tip = NSBezierPath()
    let tx = appsX - 74
    tip.move(to: NSPoint(x: tx - 13, y: y + 10))
    tip.line(to: NSPoint(x: tx, y: y))
    tip.line(to: NSPoint(x: tx - 13, y: y - 9))
    tip.lineWidth = 3
    tip.lineCapStyle = .round
    tip.lineJoinStyle = .round
    tip.stroke()
    text("Glisse Zeste dans Applications", 12, .semibold, 0.9, x: (appX + appsX) / 2, y: iconY - 62, center: true)

    // Rappel des cinq roues, en pastilles.
    let keys: [(String, String)] = [("⇧", "Convertir"), ("⌘", "Outils"), ("⌃", "Actions"), ("⌥", "Extras"), ("⇧⌘", "Éditer")]
    let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    let keyFont = NSFont.systemFont(ofSize: 12, weight: .bold)
    let widths = keys.map { k in
        (k.0 as NSString).size(withAttributes: [.font: keyFont]).width + (k.1 as NSString).size(withAttributes: [.font: font]).width + 30
    }
    let gap: CGFloat = 8
    var x = (W - widths.reduce(0, +) - gap * CGFloat(keys.count - 1)) / 2
    let py = flipY(366) - 13
    text("Une fois installée : glisse un fichier, et sans lâcher, appuie sur", 11.5, .medium, 0.7, x: W / 2, y: 330, center: true)
    for (i, k) in keys.enumerated() {
        let r = NSRect(x: x, y: py, width: widths[i], height: 26)
        NSColor(white: 1, alpha: 0.14).setFill()
        NSBezierPath(roundedRect: r, xRadius: 13, yRadius: 13).fill()
        let kw = (k.0 as NSString).size(withAttributes: [.font: keyFont]).width
        (k.0 as NSString).draw(at: NSPoint(x: r.minX + 11, y: r.minY + 5), withAttributes: [.font: keyFont, .foregroundColor: NSColor.white])
        (k.1 as NSString).draw(at: NSPoint(x: r.minX + 17 + kw, y: r.minY + 5.5),
                               withAttributes: [.font: font, .foregroundColor: NSColor(white: 1, alpha: 0.85)])
        x += widths[i] + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: URL(fileURLWithPath: "\(outDir)/bg.png"))
try! render(scale: 2).write(to: URL(fileURLWithPath: "\(outDir)/bg@2x.png"))
