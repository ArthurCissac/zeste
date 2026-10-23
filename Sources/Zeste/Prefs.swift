import AppKit

enum ModKey: String, CaseIterable, Identifiable {
    case shift, command, control, option

    var id: String { rawValue }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        }
    }

    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        }
    }

    var label: String {
        switch self {
        case .shift: return "⇧ Maj"
        case .command: return "⌘ Commande"
        case .control: return "⌃ Contrôle"
        case .option: return "⌥ Option"
        }
    }
}

enum OutputPlace: String, CaseIterable, Identifiable {
    case beside, downloads, desktop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .beside: return "À côté du fichier d'origine"
        case .downloads: return "Téléchargements"
        case .desktop: return "Bureau"
        }
    }
}

/// Réglages, lus dans UserDefaults (mêmes clés que la fenêtre SwiftUI).
enum Prefs {
    private static var d: UserDefaults { .standard }

    static func key(for mode: Mode) -> ModKey {
        let defaults: [Mode: ModKey] = [.convert: .shift, .tools: .command, .actions: .control]
        let names: [Mode: String] = [.convert: "convertKey", .tools: "toolsKey", .actions: "actionsKey"]
        return ModKey(rawValue: d.string(forKey: names[mode]!) ?? "") ?? defaults[mode]!
    }

    static var output: OutputPlace { OutputPlace(rawValue: d.string(forKey: "output") ?? "") ?? .beside }

    /// Qualité des formats avec perte (JPEG, HEIC, AVIF, WebP), de 0,4 à 1.
    static var quality: Double {
        let q = d.object(forKey: "quality") as? Double ?? 0.85
        return min(1, max(0.4, q))
    }

    static var sound: Bool { d.object(forKey: "sound") as? Bool ?? true }
}
