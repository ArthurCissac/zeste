import AppKit

/// Bulle d'état en bas de l'écran : progression, réussite (« Afficher »), erreur.
@MainActor
final class HUD: NSObject {
    static let shared = HUD()
    var enabled = true

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let button = NSButton(title: "Afficher", target: nil, action: nil)
    private let stack: NSStackView
    private var reveal: [URL] = []
    private var hideWork: DispatchWorkItem?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        stack = NSStackView(views: [spinner, label, button])
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.state = .active
        fx.blendingMode = .behindWindow
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true

        spinner.style = .spinning
        spinner.controlSize = .small
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = 420
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(revealNow)

        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor),
            stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        panel.contentView = fx
    }

    func show(_ text: String, spinning: Bool = false, reveal: [URL] = [], duration: Double = 4) {
        guard enabled else { print(text); return }
        hideWork?.cancel()
        label.stringValue = text
        spinner.isHidden = !spinning
        spinning ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        self.reveal = reveal
        button.isHidden = reveal.isEmpty

        let size = stack.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.minY + 48, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()

        if !spinning {
            let w = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: w)
        }
    }

    func hide() { hideWork?.cancel(); panel.orderOut(nil) }

    @objc private func revealNow() {
        NSWorkspace.shared.activateFileViewerSelecting(reveal)
        hide()
    }
}

/// Lance une option et rend compte du résultat.
@MainActor
enum Runner {
    static var partialErrors: [String] = []
    /// Message de fin fourni par l'option elle-même (« Texte copié »…), prioritaire.
    static var note: String?

    static func run(_ opt: Option, _ files: [URL]) {
        Task { @MainActor in
            partialErrors = []
            note = nil
            HUD.shared.show("\(opt.title)…", spinning: true)
            do {
                let outs = try await opt.run(files)
                if let n = note, outs.isEmpty {
                    HUD.shared.show("✓ " + n, duration: 6)
                } else if let done = opt.done {
                    HUD.shared.show("✓ " + done(files.count), reveal: opt.id == "move" ? outs : [])
                } else {
                    var msg = "✓ " + (outs.count > 1 ? "\(outs.count) fichiers créés" : (outs.first?.lastPathComponent ?? "Terminé"))
                    if !partialErrors.isEmpty { msg += " · \(partialErrors.count) échec(s) : \(partialErrors[0])" }
                    if let n = note { msg += " · " + n }
                    HUD.shared.show(msg, reveal: outs, duration: partialErrors.isEmpty ? 5 : 9)
                }
                if Prefs.sound { NSSound(named: "Glass")?.play() }
            } catch ZError.cancelled {
                HUD.shared.hide()
            } catch {
                HUD.shared.show("✗ " + error.localizedDescription, duration: 9)
                NSSound(named: "Basso")?.play()
            }
        }
    }
}
