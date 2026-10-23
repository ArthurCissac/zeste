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
        let head = NSMenuItem(title: "Zeste : glisse un fichier, puis ⇧ ⌘ ⌃ ⌥ ou ⇧⌘", action: nil, keyEquivalent: "")
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
        HiddenLauncher.start()
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
        \(k(.edit))  pour éditer (retoucher une photo, retirer le fond, couper avec la forme d'onde)
        \(k(.extras))  pour les extras (formats réseaux sociaux, sous-titres auto, lire le texte, taille cible…)

        Une roue apparaît : dépose le fichier sur la part voulue. Au centre, tu annules. Le fichier créé arrive à côté de l'original.

        Sans souris : sélectionne un fichier dans le Finder et fais ⌃⌥Espace, puis flèches, Tab et Entrée.

        Tout se passe sur ton Mac, rien n'est envoyé sur internet.
        """
        a.addButton(withTitle: "C'est parti")
        a.runModal()
    }

    /// Rouvrir Zeste (Spotlight, Finder) alors qu'il tourne déjà affiche les réglages :
    /// l'icône de la barre des menus peut être cachée par l'encoche quand il y en a beaucoup.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
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
    @AppStorage("extrasKey") private var extrasKey = ModKey.option.rawValue
    @AppStorage("editKey") private var editKey = ModKey.shiftCommand.rawValue
    @AppStorage("speechLang") private var speechLang = "fr-FR"
    @AppStorage("output") private var output = OutputPlace.beside.rawValue
    @AppStorage("quality") private var quality = 0.85
    @AppStorage("sound") private var sound = true
    @AppStorage("accent") private var accent = Accent.violet.rawValue
    @AppStorage("clicks") private var clicks = true
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var hidden = HiddenLauncher.paths
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Touches pendant le glisser") {
                keyPicker("Convertir", $convertKey)
                keyPicker("Outils", $toolsKey)
                keyPicker("Actions", $actionsKey)
                keyPicker("Extras", $extrasKey)
                keyPicker("Éditer", $editKey)
                if Set([convertKey, toolsKey, actionsKey, extrasKey, editKey]).count < 5 {
                    Text("Deux roues utilisent la même touche : choisis cinq combinaisons différentes.")
                        .foregroundStyle(.orange).font(.callout)
                }
            }
            Section("Apparence") {
                Picker("Couleur de la roue", selection: $accent) {
                    ForEach(Accent.allCases) { a in
                        HStack {
                            Image(systemName: "circle.fill").foregroundStyle(Color(nsColor: a.color))
                            Text(a.label)
                        }.tag(a.rawValue)
                    }
                }
                Toggle("Petits clics et vibration au survol", isOn: $clicks)
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
            Section {
                ForEach(hidden, id: \.self) { p in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 20, height: 20)
                        Text(URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent)
                        Spacer()
                        Button { hidden.removeAll { $0 == p }; HiddenLauncher.paths = hidden } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.borderless)
                    }
                }
                Button("Ajouter une app…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.application]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK {
                        for u in panel.urls where !hidden.contains(u.path) { hidden.append(u.path) }
                        HiddenLauncher.paths = hidden
                    }
                }
            } header: {
                Text("Ouvrir cachées au démarrage")
            } footer: {
                Text("Zeste les ouvre en arrière-plan, sans fenêtre : elles restent utilisables depuis la barre des menus. Retire-les de Réglages Système › Général › Ouverture pour éviter une double ouverture.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Picker("Langue des sous-titres", selection: $speechLang) {
                    Text("Français").tag("fr-FR"); Text("Anglais (US)").tag("en-US"); Text("Anglais (UK)").tag("en-GB")
                    Text("Espagnol").tag("es-ES"); Text("Allemand").tag("de-DE"); Text("Italien").tag("it-IT")
                }
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
                v.settle()
                // Roue + onglets, sur fond blanc : le pire cas de lisibilité.
                let tabs = WheelTabs(frame: NSRect(x: 0, y: 0, width: 420, height: 52))
                tabs.mode = mode
                let box = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 472))
                v.frame.origin.y = 52
                box.addSubview(v); box.addSubview(tabs)
                let rep = box.bitmapImageRepForCachingDisplay(in: box.bounds)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor.white.setFill()
                box.bounds.fill()
                NSGraphicsContext.restoreGraphicsState()
                box.cacheDisplay(in: box.bounds, to: rep)
                do { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2])) }
                catch { print("snapshot :", error.localizedDescription) }
                exit(0)
            }
            if first == "render-editor", args.count >= 3 {
                // Zeste --run render-editor <fichier> <sortie.png> : capture de l'éditeur, pour vérifier la mise en page.
                let u = URL(fileURLWithPath: args[1])
                let win = NSWindow()
                let view: AnyView
                if u.kind == .image {
                    let m = try! PhotoModel(url: u)
                    m.look.exposure = 0.6; m.look.warmth = 0.5
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    view = AnyView(PhotoEditorView(model: m, window: win))
                } else {
                    let m = TrimModel(url: u)
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    m.start = m.duration * 0.2; m.end = m.duration * 0.75; m.playhead = m.duration * 0.4
                    view = AnyView(TrimEditorView(model: m, window: win))
                }
                let host = NSHostingView(rootView: view.frame(width: 1100, height: u.kind == .image ? 700 : 380))
                host.frame = NSRect(x: 0, y: 0, width: 1100, height: u.kind == .image ? 700 : 380)
                win.contentView = host
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 300_000_000)
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
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
                if let n = Runner.note { print("NOTE :", n) }
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
