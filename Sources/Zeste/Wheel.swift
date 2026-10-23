import AppKit

final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// La roue radiale : apparaît sous le curseur pendant un glisser (ou au clavier),
/// chaque part est une cible de dépôt.
@MainActor
final class Wheel: NSObject, NSWindowDelegate {
    static let shared = Wheel()

    let size: CGFloat = 420
    let panel: WheelPanel
    let view: WheelView
    private(set) var files: [URL] = []
    private(set) var mode: Mode = .convert
    private(set) var keyboardMode = false

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        view = WheelView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 10, dy: 10))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = (size - 20) / 2
        blur.layer?.masksToBounds = true

        let root = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        root.addSubview(blur)
        root.addSubview(view)
        panel.contentView = root
        view.owner = self
    }

    func show(mode: Mode, files: [URL], at point: NSPoint?, keyboard: Bool) {
        self.files = files
        self.keyboardMode = keyboard
        apply(mode)
        let screen = NSScreen.screens.first { NSMouseInRect(point ?? NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.frame
        var c = point ?? NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        c.x = min(max(c.x, vf.minX + size / 2), vf.maxX - size / 2)
        c.y = min(max(c.y, vf.minY + size / 2), vf.maxY - size / 2)
        panel.setFrameOrigin(NSPoint(x: c.x - size / 2, y: c.y - size / 2))
        panel.alphaValue = 1
        if keyboard {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func switchMode(_ m: Mode) {
        guard isVisible, m != mode else { return }
        apply(m)
    }

    private func apply(_ m: Mode) {
        mode = m
        view.mode = m
        view.fileCount = files.count
        view.options = Catalog.options(for: files, mode: m)
        view.hover = keyboardMode && !view.options.isEmpty ? 0 : nil
        view.needsDisplay = true
    }

    func cycleMode(_ step: Int) {
        let all = Mode.allCases
        apply(all[(mode.rawValue + step + all.count) % all.count])
    }

    func hide() {
        panel.orderOut(nil)
        keyboardMode = false
    }

    func perform(_ index: Int, files dropped: [URL]? = nil) {
        guard index >= 0, index < view.options.count else { return }
        let opt = view.options[index]
        let list = (dropped?.isEmpty == false) ? dropped! : files
        hide()
        Runner.run(opt, list)
    }

    func windowDidResignKey(_ notification: Notification) {
        if keyboardMode { hide() }
    }
}

final class WheelView: NSView {
    weak var owner: Wheel?
    var options: [Option] = []
    var mode: Mode = .convert
    var fileCount = 0
    var hover: Int? { didSet { if oldValue != hover { needsDisplay = true } } }

    let inner: CGFloat = 70
    let outer: CGFloat = 196
    let accent = NSColor(red: 0.16, green: 0.80, blue: 0.47, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    /// Part sous le point ; nil au centre (annuler) ou hors de la roue.
    func index(at p: NSPoint) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y
        let r = hypot(dx, dy)
        guard !options.isEmpty, r >= inner, r <= outer + 14 else { return nil }
        var a = atan2(dx, dy) // 0 en haut, sens horaire
        if a < 0 { a += 2 * .pi }
        let step = 2 * CGFloat.pi / CGFloat(options.count)
        return Int(((a + step / 2).truncatingRemainder(dividingBy: 2 * .pi)) / step) % options.count
    }

    // MARK: Dessin

    override func draw(_ dirtyRect: NSRect) {
        let n = options.count
        if n > 0 {
            let step = 360 / CGFloat(n)
            let gap: CGFloat = n > 1 ? 1.2 : 0
            for i in 0..<n {
                // Angles AppKit : degrés, sens antihoraire depuis l'axe x.
                let startCW = CGFloat(i) * step - step / 2 + gap
                let endCW = CGFloat(i) * step + step / 2 - gap
                let a1 = 90 - startCW, a2 = 90 - endCW
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: outer, startAngle: a1, endAngle: a2, clockwise: true)
                path.appendArc(withCenter: center, radius: inner + 4, startAngle: a2, endAngle: a1, clockwise: false)
                path.close()
                (hover == i ? accent : NSColor(white: 1, alpha: 0.07)).setFill()
                path.fill()

                let mid = (90 - CGFloat(i) * step) * .pi / 180
                let rr = (inner + outer) / 2 + 4
                let pt = NSPoint(x: center.x + cos(mid) * rr, y: center.y + sin(mid) * rr)
                drawItem(options[i], at: pt, highlighted: hover == i, crowded: n > 8)
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
            sub = mode.title
        } else {
            title = mode.title
            sub = fileCount > 1 ? "\(fileCount) fichiers" : "1 fichier"
        }
        drawCentered(title, y: center.y + 4, size: title.count > 12 ? 11 : 14, weight: .bold, color: .white, width: (inner - 10) * 2)
        drawCentered(sub, y: center.y - 14, size: 10, weight: .medium, color: NSColor(white: 1, alpha: 0.65), width: (inner - 10) * 2)

        // Rappel des touches des trois roues
        let keys = Mode.allCases.map { (Prefs.key(for: $0).symbol, $0 == mode) }
        let total = CGFloat(keys.count) * 18
        for (i, k) in keys.enumerated() {
            let x = center.x - total / 2 + CGFloat(i) * 18 + 9
            drawCentered(k.0, y: center.y - 36, size: 11, weight: .bold,
                         color: k.1 ? accent : NSColor(white: 1, alpha: 0.4), width: 18, centerX: x)
        }
    }

    private func drawItem(_ o: Option, at p: NSPoint, highlighted: Bool, crowded: Bool) {
        let iconSize: CGFloat = crowded ? 20 : 24
        let cfg = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [highlighted ? .black : .white]))
        let img = (NSImage(systemSymbolName: o.symbol, accessibilityDescription: o.title)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil))?.withSymbolConfiguration(cfg)
        if let img {
            let s = img.size
            img.draw(in: NSRect(x: p.x - s.width / 2, y: p.y + 2, width: s.width, height: s.height))
        }
        drawCentered(o.title, y: p.y - 16, size: crowded ? 9.5 : 10.5, weight: .semibold,
                     color: highlighted ? .black : .white, width: crowded ? 70 : 86, centerX: p.x)
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
        for m in Mode.allCases where event.modifierFlags.contains(Prefs.key(for: m).flag) {
            owner?.switchMode(m)
            return
        }
    }
}
