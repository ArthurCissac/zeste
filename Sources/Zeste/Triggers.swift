import AppKit
import Carbon

/// Détecte un glisser de fichiers n'importe où sur le Mac, puis l'appui d'une des trois touches.
/// Ne lit que les clics de souris (aucune frappe clavier) : pas besoin de l'autorisation Accessibilité.
@MainActor
final class DragWatcher {
    private var monitors: [Any] = []
    private var startCount = 0
    private var active = false
    private var files: [URL] = []
    private var timer: Timer?

    func start() {
        let pairs: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            (.leftMouseDown, { [weak self] _ in MainActor.assumeIsolated { self?.down() } }),
            (.leftMouseDragged, { [weak self] _ in MainActor.assumeIsolated { self?.dragged() } }),
            (.leftMouseUp, { [weak self] _ in MainActor.assumeIsolated { self?.up() } }),
        ]
        for (mask, handler) in pairs {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(m) }
        }
    }

    private func down() {
        startCount = NSPasteboard(name: .drag).changeCount
        active = false
    }

    private func dragged() {
        guard !active else { return }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != startCount else { return }
        startCount = pb.changeCount
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        active = true
        files = urls
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    private func tick() {
        guard let m = Prefs.mode(for: NSEvent.modifierFlags) else { return }
        let wheel = Wheel.shared
        if wheel.isVisible { wheel.switchMode(m) }
        else { wheel.show(mode: m, files: files, at: NSEvent.mouseLocation, keyboard: false) }
    }

    private func up() {
        timer?.invalidate()
        timer = nil
        guard active else { return }
        active = false
        // Le dépôt arrive juste après le relâchement : on laisse la roue le recevoir avant de la fermer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MainActor.assumeIsolated {
            if !Wheel.shared.keyboardMode { Wheel.shared.hide() }
        } }
    }
}

/// Raccourci global ⌃⌥Espace : ouvre la roue sur la sélection du Finder, au clavier.
enum HotKey {
    static var handler: (@MainActor () -> Void)?
    private static var ref: EventHotKeyRef?

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.handler?() } }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5A45_5354), id: 1) // « ZEST »
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}

@MainActor
enum FinderSelection {
    static func get() async -> [URL] {
        let script = """
        tell application "Finder"
            set out to ""
            repeat with f in (get selection as alias list)
                set out to out & POSIX path of f & linefeed
            end repeat
            return out
        end tell
        """
        guard let s = try? await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 10) else { return [] }
        return s.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    static func openWheel() {
        Task { @MainActor in
            let files = await get()
            guard !files.isEmpty else {
                HUD.shared.show("Sélectionne d'abord un fichier dans le Finder")
                return
            }
            Wheel.shared.show(mode: .convert, files: files, at: nil, keyboard: true)
        }
    }
}
