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

/// Couleur de la roue (part survolée, touche active).
enum Accent: String, CaseIterable, Identifiable {
    case violet, indigo, bleu, cyan, orange, ambre, rose, rouge, graphite

    var id: String { rawValue }

    var color: NSColor {
        func rgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        switch self {
        case .violet: return rgb(0x8B5CF6)
        case .indigo: return rgb(0x6366F1)
        case .bleu: return rgb(0x3B82F6)
        case .cyan: return rgb(0x22D3EE)
        case .orange: return rgb(0xFF8A1F)
        case .ambre: return rgb(0xFBBF24)
        case .rose: return rgb(0xEC4899)
        case .rouge: return rgb(0xEF4444)
        case .graphite: return rgb(0xD4D4D8)
        }
    }

    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
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

    static var accent: Accent { Accent(rawValue: d.string(forKey: "accent") ?? "") ?? .violet }

    /// Petits clics et retour haptique au survol de la roue.
    static var clicks: Bool { d.object(forKey: "clicks") as? Bool ?? true }
}
