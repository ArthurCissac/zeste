import AppKit
import QuartzCore

final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// La roue radiale : apparaît sous le curseur pendant un glisser (ou au clavier),
/// chaque part est une cible de dépôt.
@MainActor
final class Wheel: NSObject, NSWindowDelegate {
    static let shared = Wheel()

    let size: CGFloat = 440
    let panel: WheelPanel
    let view: WheelView
    private let root: NSView
    private(set) var files: [URL] = []
    private(set) var mode: Mode = .convert
    private(set) var keyboardMode = false
    /// Incrémenté à chaque ouverture : une fermeture animée en cours ne doit pas masquer la roue rouverte.
    private var generation = 0

    var isVisible: Bool { panel.isVisible && panel.alphaValue > 0.01 }

    override init() {
        panel = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        view = WheelView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        root = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.appearance = NSAppearance(named: .darkAqua)

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 20, dy: 20))
        // Toujours sombre : en mode clair, le flou devenait blanc et le texte blanc disparaissait.
        blur.appearance = NSAppearance(named: .vibrantDark)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = (size - 40) / 2
        blur.layer?.masksToBounds = true

        root.wantsLayer = true
        root.addSubview(blur)
        root.addSubview(view)
        panel.contentView = root
        view.owner = self
    }

    func show(mode: Mode, files: [URL], at point: NSPoint?, keyboard: Bool) {
        generation += 1
        self.files = files
        self.keyboardMode = keyboard
        apply(mode, animated: false)
        let screen = NSScreen.screens.first { NSMouseInRect(point ?? NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.frame
        var c = point ?? NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        c.x = min(max(c.x, vf.minX + size / 2), vf.maxX - size / 2)
        c.y = min(max(c.y, vf.minY + size / 2), vf.maxY - size / 2)
        panel.setFrameOrigin(NSPoint(x: c.x - size / 2, y: c.y - size / 2))

        // Ouverture : fondu + léger rebond depuis 80 %.
        panel.alphaValue = 0
        if keyboard {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        } else {
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        pop(from: 0.8)
        view.startIntro()
        Feedback.open()
    }

    private func pop(from scale: CGFloat) {
        guard let layer = root.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: size / 2, y: size / 2)
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = scale
        spring.toValue = 1
        spring.damping = 16
        spring.stiffness = 320
        spring.mass = 0.8
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pop")
    }

    func switchMode(_ m: Mode) {
        guard isVisible, m != mode else { return }
        apply(m, animated: true)
    }

    private func apply(_ m: Mode, animated: Bool) {
        mode = m
        view.mode = m
        view.fileCount = files.count
        view.options = Catalog.options(for: files, mode: m)
        view.hover = keyboardMode && !view.options.isEmpty ? 0 : nil
        view.needsDisplay = true
        if animated {
            view.startIntro()
            pop(from: 0.94)
            Feedback.tick()
        }
    }

    func cycleMode(_ step: Int) {
        let all = Mode.allCases
        apply(all[(mode.rawValue + step + all.count) % all.count], animated: true)
    }

    func hide() {
        keyboardMode = false
        guard panel.isVisible else { return }
        let g = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == g else { return }
                self.panel.orderOut(nil)
                self.view.hover = nil
            }
        })
    }

    func perform(_ index: Int, files dropped: [URL]? = nil) {
        guard index >= 0, index < view.options.count else { return }
        let opt = view.options[index]
        let list = (dropped?.isEmpty == false) ? dropped! : files
        Feedback.select()
        hide()
        Runner.run(opt, list)
    }

    func windowDidResignKey(_ notification: Notification) {
        if keyboardMode { hide() }
    }
}

final class WheelView: NSView {
    weak var owner: Wheel?
    var options: [Option] = [] { didSet { glow = Array(repeating: 0, count: options.count) } }
    var mode: Mode = .convert
    var fileCount = 0
    var hover: Int? {
        didSet {
            guard oldValue != hover else { return }
            if hover != nil { Feedback.tick() }
            animate()
        }
    }

    let inner: CGFloat = 70
    let outer: CGFloat = 196
    var accent: NSColor { Prefs.accent.color }

    // Animation : `glow` va de 0 à 1 pour chaque part survolée, `intro` de 0 à 1 à l'ouverture.
    private var glow: [CGFloat] = []
    private var introStart: CFTimeInterval = 0
    private var intro: CGFloat = 1
    private var lastTick: CFTimeInterval = 0
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    // MARK: Animation

    /// Fige l'animation à son état final (rendu de la roue en ligne de commande).
    func settle() {
        intro = 1
        for i in glow.indices { glow[i] = hover == i ? 1 : 0 }
        timer?.invalidate(); timer = nil
    }

    func startIntro() {
        introStart = CACurrentMediaTime()
        intro = 0
        animate()
    }

    private func animate() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.step() } }
        // Mode .common : la roue doit s'animer même pendant un glisser.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func step() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastTick, 1 / 30))
        lastTick = now
        intro = min(1, CGFloat((now - introStart) / 0.26))
        var settled = intro >= 1
        for i in glow.indices {
            let target: CGFloat = hover == i ? 1 : 0
            glow[i] += (target - glow[i]) * min(1, dt * 22)
            if abs(target - glow[i]) < 0.005 { glow[i] = target } else { settled = false }
        }
        needsDisplay = true
        if settled { timer?.invalidate(); timer = nil }
    }

    /// Courbe d'arrivée avec un léger dépassement, part par part (en cascade).
    private func introAmount(_ i: Int, of n: Int) -> CGFloat {
        let delay = n > 0 ? CGFloat(i) / CGFloat(n) * 0.35 : 0
        let t = max(0, min(1, (intro - delay) / (1 - 0.35)))
        let c1: CGFloat = 1.7, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }

    /// Index de la part sous le point ; nil au centre (annuler) ou hors de la roue.
    func index(at p: NSPoint) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y
        let r = hypot(dx, dy)
        guard !options.isEmpty, r >= inner, r <= outer + 24 else { return nil }
        var a = atan2(dx, dy) // 0 en haut, sens horaire
        if a < 0 { a += 2 * .pi }
        let step = 2 * CGFloat.pi / CGFloat(options.count)
        return Int(((a + step / 2).truncatingRemainder(dividingBy: 2 * .pi)) / step) % options.count
    }

    // MARK: Dessin

    override func draw(_ dirtyRect: NSRect) {
        let n = options.count
        let base = NSColor(white: 1, alpha: 0.08)

        // Disque sombre sous les parts : lisible même au-dessus d'une fenêtre blanche.
        let disc = NSBezierPath(ovalIn: NSRect(x: center.x - outer - 4, y: center.y - outer - 4, width: (outer + 4) * 2, height: (outer + 4) * 2))
        NSColor(white: 0.07, alpha: 0.86).setFill()
        disc.fill()
        let ink = accent.isLight ? NSColor.black : NSColor.white

        if n > 0 {
            let step = 360 / CGFloat(n)
            let gap: CGFloat = n > 1 ? 1.2 : 0
            for i in 0..<n {
                let g = i < glow.count ? glow[i] : 0
                let k = introAmount(i, of: n)
                let alpha = min(1, max(0, k))
                // La part survolée sort de la roue et grossit un peu.
                let rOut = inner + 4 + (outer - inner - 4) * k + 10 * g
                let rIn = inner + 4 + 2 * g
                let startCW = CGFloat(i) * step - step / 2 + gap
                let endCW = CGFloat(i) * step + step / 2 - gap
                let a1 = 90 - startCW, a2 = 90 - endCW
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: max(rOut, rIn + 1), startAngle: a1, endAngle: a2, clockwise: true)
                path.appendArc(withCenter: center, radius: rIn, startAngle: a2, endAngle: a1, clockwise: false)
                path.close()

                NSGraphicsContext.saveGraphicsState()
                if g > 0.01 {
                    let shadow = NSShadow()
                    shadow.shadowColor = accent.withAlphaComponent(0.55 * g)
                    shadow.shadowBlurRadius = 18 * g
                    shadow.set()
                }
                (base.blended(withFraction: g, of: accent) ?? base).withAlphaComponent((0.07 + 0.93 * g) * alpha).setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()

                let mid = (90 - CGFloat(i) * step) * .pi / 180
                let rr = (inner + outer) / 2 + 4 + 5 * g
                let reach = inner + (rr - inner) * k
                let pt = NSPoint(x: center.x + cos(mid) * reach, y: center.y + sin(mid) * reach)
                let color = (NSColor.white.blended(withFraction: g, of: ink) ?? .white).withAlphaComponent(alpha)
                drawItem(options[i], at: pt, color: color, scale: 1 + 0.16 * g, crowded: n > 8)
            }
        }

        // Centre
        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - inner + 6, y: center.y - inner + 6, width: (inner - 6) * 2, height: (inner - 6) * 2))
        NSColor(white: 0, alpha: 0.35).setFill()
        hub.fill()

        let title: String
        let sub: String
        if n == 0 {
            title = mode.title
            sub = "Rien pour ce fichier"
        } else if let h = hover, h < n {
            title = options[h].title
            sub = "\(Prefs.key(for: mode).symbol) \(mode.title)"
        } else {
            title = mode.title
            sub = "\(Prefs.key(for: mode).symbol) · " + (fileCount > 1 ? "\(fileCount) fichiers" : "1 fichier")
        }
        drawCentered(title, y: center.y + 4, size: title.count > 12 ? 11 : 14, weight: .bold, color: .white, width: (inner - 10) * 2)
        drawCentered(sub, y: center.y - 14, size: 10, weight: .medium, color: NSColor(white: 1, alpha: 0.65), width: (inner - 10) * 2)

    }

    private func drawItem(_ o: Option, at p: NSPoint, color: NSColor, scale: CGFloat, crowded: Bool) {
        let iconSize: CGFloat = (crowded ? 20 : 24) * scale
        let cfg = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let img = (NSImage(systemSymbolName: o.symbol, accessibilityDescription: o.title)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil))?.withSymbolConfiguration(cfg)
        if let img {
            let s = img.size
            img.draw(in: NSRect(x: p.x - s.width / 2, y: p.y + 2, width: s.width, height: s.height))
        }
        drawCentered(o.title, y: p.y - 16, size: (crowded ? 9.5 : 10.5) * min(scale, 1.08), weight: .semibold,
                     color: color, width: crowded ? 74 : 90, centerX: p.x)
    }

    private func drawCentered(_ s: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, width: CGFloat, centerX: CGFloat? = nil) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: para]
        let h = size + 6
        let x = (centerX ?? center.x) - width / 2
        (s as NSString).draw(with: NSRect(x: x, y: y - h / 2 + 2, width: width, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    // MARK: Dépôt

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { hover = nil }

    private func track(_ s: NSDraggingInfo) -> NSDragOperation {
        hover = index(at: convert(s.draggingLocation, from: nil))
        return hover == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { hover != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let i = hover else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        DispatchQueue.main.async { self.owner?.perform(i, files: urls) }
        return true
    }

    // MARK: Souris et clavier (mode sans glisser)

    override func mouseMoved(with event: NSEvent) {
        guard owner?.keyboardMode == true else { return }
        if let i = index(at: convert(event.locationInWindow, from: nil)) { hover = i }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = index(at: p) { owner?.perform(i) }
        else if hypot(p.x - center.x, p.y - center.y) < inner { owner?.hide() }
    }

    override func keyDown(with event: NSEvent) {
        let n = options.count
        switch event.keyCode {
        case 53: owner?.hide() // Échap
        case 36, 76: if let h = hover { owner?.perform(h) } // Entrée
        case 48: owner?.cycleMode(event.modifierFlags.contains(.shift) ? -1 : 1) // Tab
        case 124, 125: if n > 0 { hover = ((hover ?? -1) + 1) % n }
        case 123, 126: if n > 0 { hover = ((hover ?? 0) - 1 + n) % n }
        default: super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if let m = Prefs.mode(for: event.modifierFlags) { owner?.switchMode(m) }
    }
}

extension NSColor {
    /// Couleur claire : on écrit en noir par-dessus.
    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.62
    }
}
