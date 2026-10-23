import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private let watcher = DragWatcher()
    private var settings: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "circle.dashed.inset.filled", accessibilityDescription: "Zeste")

        let menu = NSMenu()
        let head = NSMenuItem(title: "Zeste : glisse un fichier, puis ⇧ ⌘ ou ⌃", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        menu.addItem(item("Convertir la sélection du Finder (⌃⌥Espace)", #selector(openFromFinder)))
        menu.addItem(item("Comment ça marche", #selector(showHelp)))
        menu.addItem(item("Réglages…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quitter Zeste", #selector(quit), key: "q"))
        status.menu = menu

        watcher.start()
        HotKey.handler = { FinderSelection.openWheel() }
        HotKey.register()

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.showHelp() }
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openFromFinder() { FinderSelection.openWheel() }

    @objc func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Bienvenue dans Zeste"
        let k = { (m: Mode) in Prefs.key(for: m).symbol }
        a.informativeText = """
        Fais glisser un ou plusieurs fichiers (depuis le Finder, le Bureau, Mail…) et, sans lâcher, appuie sur :

        \(k(.convert))  pour convertir (JPG, WebP, MP4, PDF, Word…)
        \(k(.tools))  pour les outils (compresser, couper, fusionner…)
        \(k(.actions))  pour les actions (AirDrop, copier le chemin…)

        Une roue apparaît : dépose le fichier sur la part voulue. Au centre, tu annules. Le fichier créé arrive à côté de l'original.

        Sans souris : sélectionne un fichier dans le Finder et fais ⌃⌥Espace, puis flèches, Tab et Entrée.

        Tout se passe sur ton Mac, rien n'est envoyé sur internet.
        """
        a.addButton(withTitle: "C'est parti")
        a.runModal()
    }

    @objc private func openSettings() {
        if settings == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Réglages de Zeste"
            w.contentView = NSHostingView(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.center()
            settings = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

struct SettingsView: View {
    @AppStorage("convertKey") private var convertKey = ModKey.shift.rawValue
    @AppStorage("toolsKey") private var toolsKey = ModKey.command.rawValue
    @AppStorage("actionsKey") private var actionsKey = ModKey.control.rawValue
    @AppStorage("output") private var output = OutputPlace.beside.rawValue
    @AppStorage("quality") private var quality = 0.85
    @AppStorage("sound") private var sound = true
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Touches pendant le glisser") {
                keyPicker("Convertir", $convertKey)
                keyPicker("Outils", $toolsKey)
                keyPicker("Actions", $actionsKey)
                if Set([convertKey, toolsKey, actionsKey]).count < 3 {
                    Text("Deux roues utilisent la même touche : choisis trois touches différentes.")
                        .foregroundStyle(.orange).font(.callout)
                }
            }
            Section("Fichiers créés") {
                Picker("Emplacement", selection: $output) {
                    ForEach(OutputPlace.allCases) { Text($0.label).tag($0.rawValue) }
                }
                VStack(alignment: .leading) {
                    Slider(value: $quality, in: 0.4...1.0, step: 0.05)
                    Text("Qualité JPG, HEIC, AVIF, WebP : \(Int(quality * 100)) %").font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Général") {
                Toggle("Ouvrir Zeste au démarrage du Mac", isOn: $atLogin)
                    .onChange(of: atLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch { loginError = error.localizedDescription }
                    }
                if let e = loginError { Text(e).foregroundStyle(.red).font(.callout) }
                Toggle("Son à la fin d'une conversion", isOn: $sound)
                LabeledContent("Sans souris", value: "⌃⌥Espace sur une sélection du Finder")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }

    private func keyPicker(_ title: String, _ binding: Binding<String>) -> some View {
        Picker(title, selection: binding) {
            ForEach(ModKey.allCases) { Text($0.label).tag($0.rawValue) }
        }
    }
}

/// Mode ligne de commande, pour tester les conversions sans interface :
///   Zeste --run list <fichiers…>
///   Zeste --run <id-option> <fichiers…>
@MainActor
enum CLI {
    static func run(_ args: [String]) -> Never {
        _ = NSApplication.shared
        HUD.shared.enabled = false
        Task { @MainActor in
            guard let first = args.first else { print("usage : --run list|<option> fichiers…"); exit(2) }
            let files = args.dropFirst().map { URL(fileURLWithPath: $0) }
            if first == "snapshot", args.count >= 4, let mode = Int(args[1]).flatMap(Mode.init(rawValue:)) {
                // Zeste --run snapshot <0|1|2> <sortie.png> <fichiers…> : rendu de la roue, pour vérifier le dessin.
                let v = WheelView(frame: NSRect(x: 0, y: 0, width: 420, height: 420))
                let list = args.dropFirst(3).map { URL(fileURLWithPath: $0) }
                v.mode = mode; v.fileCount = list.count
                v.options = Catalog.options(for: Array(list), mode: mode)
                v.hover = ProcessInfo.processInfo.environment["ZESTE_HOVER"].flatMap { Int($0) }
                let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor(white: 0.12, alpha: 1).setFill()
                NSBezierPath(ovalIn: v.bounds.insetBy(dx: 10, dy: 10)).fill()
                NSGraphicsContext.restoreGraphicsState()
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
                exit(0)
            }
            if first == "list" {
                for m in Mode.allCases {
                    print("\(m.title) : " + Catalog.options(for: files, mode: m).map(\.id).joined(separator: ", "))
                }
                exit(0)
            }
            let all = Mode.allCases.flatMap { Catalog.options(for: files, mode: $0) }
            guard let opt = all.first(where: { $0.id == first }) else { print("option inconnue : \(first)"); exit(2) }
            do {
                let outs = try await opt.run(files)
                outs.forEach { print($0.path) }
                Runner.partialErrors.forEach { print("ÉCHEC PARTIEL :", $0) }
                exit(0)
            } catch {
                print("ERREUR :", error.localizedDescription)
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }
}
