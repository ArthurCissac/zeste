import AppKit
import Quartz

/// Les actions sur fichiers : rien n'est converti, on agit sur les fichiers eux-mêmes.
@MainActor
enum Actions {
    static func airdrop(_ urls: [URL]) async throws -> [URL] {
        NSApp.activate(ignoringOtherApps: true)
        guard let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: urls) else {
            throw ZError.msg("AirDrop indisponible (Wi-Fi et Bluetooth activés ?)")
        }
        s.perform(withItems: urls)
        return []
    }

    static func copy(_ urls: [URL]) async throws -> [URL] {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        return []
    }

    static func copyPath(_ urls: [URL]) async throws -> [URL] {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        return []
    }

    static func move(_ urls: [URL]) async throws -> [URL] {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Déplacer ici"
        panel.message = urls.count == 1 ? "Déplacer « \(urls[0].lastPathComponent) » vers :" : "Déplacer \(urls.count) éléments vers :"
        guard panel.runModal() == .OK, let dir = panel.url else { throw ZError.cancelled }
        var moved: [URL] = []
        for u in urls {
            let dest = Out.unique(dir.appendingPathComponent(u.lastPathComponent))
            try FileManager.default.moveItem(at: u, to: dest)
            moved.append(dest)
        }
        return moved
    }

    static func terminal(_ urls: [URL]) async throws -> [URL] {
        let dir = urls[0].isDir && urls[0].kind == .folder ? urls[0] : urls[0].deletingLastPathComponent()
        let term = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        try await NSWorkspace.shared.open([dir], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
        return []
    }

    static func float(_ urls: [URL]) async throws -> [URL] {
        for u in urls.prefix(6) { FloatWindows.show(u) }
        return []
    }
}

// MARK: - Fenêtres flottantes (aperçu toujours au premier plan, fichier redéposable)

@MainActor
enum FloatWindows {
    static var windows: [NSWindow] = []

    static func show(_ url: URL) {
        let size = NSSize(width: 340, height: 300)
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.title = url.lastPathComponent
        w.level = .floating
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        if let ql = QLPreviewView(frame: container.bounds, style: .compact) {
            ql.autoresizingMask = [.width, .height]
            ql.previewItem = url as NSURL
            container.addSubview(ql)
        }
        let handle = DragHandle(url: url)
        handle.frame = NSRect(x: 8, y: size.height - 44, width: 36, height: 36)
        handle.autoresizingMask = [.minYMargin, .maxXMargin]
        container.addSubview(handle)
        w.contentView = container

        if let screen = NSScreen.main?.visibleFrame {
            let n = CGFloat(windows.filter(\.isVisible).count)
            w.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 24 - n * 24, y: screen.maxY - size.height - 24 - n * 24))
        }
        w.orderFrontRegardless()
        windows.removeAll { !$0.isVisible }
        windows.append(w)
    }
}

/// Icône du fichier, à faire glisser depuis la fenêtre flottante vers n'importe quelle app.
final class DragHandle: NSView, NSDraggingSource {
    let url: URL
    lazy var icon: NSImage = NSWorkspace.shared.icon(forFile: url.path)

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        toolTip = "Glisser le fichier"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.35).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        icon.draw(in: bounds.insetBy(dx: 4, dy: 4))
    }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : .copy
    }
}

// MARK: - Petites boîtes de dialogue (couper, découper, extraire)

@MainActor
enum Ask {
    /// Réponse forcée pour les tests en ligne de commande (ZESTE_ANSWER="0:01|0:03").
    static var scripted: [String]? {
        ProcessInfo.processInfo.environment["ZESTE_ANSWER"].map { $0.components(separatedBy: "|") }
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// « 1:23 », « 1:02:03 », « 83 » ou « 83,5 » → secondes.
    static func seconds(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        var total = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            total = total * 60 + v
        }
        return parts.isEmpty ? nil : total
    }

    static func text(title: String, info: String, initial: String) -> String? {
        if let s = scripted { return s.first }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Annuler")
        a.window.initialFirstResponder = field
        return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func range(title: String, duration: Double) -> (Double, Double)? {
        if let s = scripted, s.count == 2, let a = seconds(s[0]), let b = seconds(s[1]) { return (a, b) }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = "Durée : \(clock(duration)). Indique le début et la fin (mm:ss)."
        let start = NSTextField(string: "0:00"), end = NSTextField(string: clock(duration))
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Début"), start], [NSTextField(labelWithString: "Fin"), end]])
        grid.frame = NSRect(x: 0, y: 0, width: 220, height: 56)
        grid.column(at: 1).width = 150
        a.accessoryView = grid
        a.addButton(withTitle: "Couper")
        a.addButton(withTitle: "Annuler")
        a.window.initialFirstResponder = start
        guard a.runModal() == .alertFirstButtonReturn,
              let s = seconds(start.stringValue), let e = seconds(end.stringValue), e > s else { return nil }
        return (s, min(e, duration > 0 ? duration : e))
    }
}
