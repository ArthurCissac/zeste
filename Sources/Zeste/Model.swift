import AppKit

// MARK: - Erreurs

enum ZError: LocalizedError {
    case msg(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .msg(let s): return s
        case .cancelled: return "Annulé"
        }
    }
}

// MARK: - Les trois roues

enum Mode: Int, CaseIterable {
    case convert, tools, actions

    var title: String { ["Convertir", "Outils", "Actions"][rawValue] }
}

/// Une entrée de roue : un format de sortie, un outil ou une action.
struct Option {
    let id: String
    let title: String
    let symbol: String
    /// Extension produite par une conversion : sert à masquer « PNG » quand tous les fichiers sont déjà en PNG.
    var target: String? = nil
    /// Message de fin pour les actions qui ne créent pas de fichier (« Chemin copié »…).
    var done: ((Int) -> String)? = nil
    let run: @MainActor ([URL]) async throws -> [URL]
}

// MARK: - Type de fichier

enum Kind: Equatable {
    case image, svg, gif, audio, video, pdf, document, pages, slides, sheet, delimited, subtitle, archive, folder, other
}

extension URL {
    var ext: String { pathExtension.lowercased() }

    /// Extension ramenée à sa forme courante (jpeg → jpg, tif → tiff…).
    var normExt: String {
        ["jpeg": "jpg", "tif": "tiff", "heif": "heic", "aif": "aiff", "m4v": "mp4", "htm": "html",
         "markdown": "md", "text": "txt", "oga": "ogg"][ext] ?? ext
    }

    var isDir: Bool { (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

    /// Nom sans extension ; « photos.tar.gz » donne « photos ».
    var baseName: String {
        var n = deletingPathExtension().lastPathComponent
        if ext == "gz" && n.lowercased().hasSuffix(".tar") { n = String(n.dropLast(4)) }
        return n
    }

    var kind: Kind {
        switch ext {
        case "jpg", "jpeg", "png", "webp", "heic", "heif", "tif", "tiff", "avif", "bmp": return .image
        case "svg": return .svg
        case "gif": return .gif
        case "mp3", "m4a", "wav", "flac", "ogg", "oga", "opus", "aif", "aiff", "wma", "aac": return .audio
        case "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "mpg", "mpeg", "3gp": return .video
        case "pdf": return .pdf
        case "rtf", "rtfd", "txt", "text", "doc", "docx", "odt", "html", "htm", "md", "markdown": return .document
        case "pages": return .pages
        case "ppt", "pptx", "key", "odp": return .slides
        case "xls", "xlsx", "numbers", "ods": return .sheet
        case "csv", "tsv": return .delimited
        case "srt", "vtt": return .subtitle
        case "zip", "tar", "gz", "tgz", "rar", "7z", "bz2", "xz": return .archive
        default: return isDir ? .folder : .other
        }
    }
}

// MARK: - Emplacement des fichiers créés

enum Out {
    static func dir(for src: URL) -> URL {
        let fm = FileManager.default
        switch Prefs.output {
        case .beside: return src.deletingLastPathComponent()
        case .downloads: return fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .desktop: return fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
    }

    /// « photo.heic » → « photo.jpg » à côté de l'original, sans jamais écraser un fichier existant.
    static func url(_ src: URL, ext: String, suffix: String? = nil) -> URL {
        var base = src.baseName
        if let s = suffix { base += " " + s }
        var u = dir(for: src).appendingPathComponent(base)
        if !ext.isEmpty { u = u.appendingPathExtension(ext) }
        return unique(u)
    }

    static func unique(_ u: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: u.path) else { return u }
        let b = u.deletingPathExtension().lastPathComponent, e = u.pathExtension, d = u.deletingLastPathComponent()
        var i = 2
        while true {
            var c = d.appendingPathComponent("\(b) \(i)")
            if !e.isEmpty { c = c.appendingPathExtension(e) }
            if !fm.fileExists(atPath: c.path) { return c }
            i += 1
        }
    }

    /// Dossier de sortie créé pour les résultats multiples (pages d'un PDF, morceaux d'une vidéo…).
    static func folder(_ src: URL, suffix: String) throws -> URL {
        let u = url(src, ext: "", suffix: suffix)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func temp(_ ext: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("zeste-" + UUID().uuidString)
        return ext.isEmpty ? u : u.appendingPathExtension(ext)
    }
}

// MARK: - Traitement fichier par fichier

/// Applique `f` à chaque fichier ; un échec n'arrête pas les suivants.
@MainActor
func each(_ urls: [URL], _ label: String, _ f: @MainActor (URL) async throws -> [URL]) async throws -> [URL] {
    var outs: [URL] = []
    var errors: [String] = []
    for (i, u) in urls.enumerated() {
        if urls.count > 1 { HUD.shared.show("\(label) \(i + 1)/\(urls.count)…", spinning: true) }
        do {
            outs += try await f(u)
        } catch ZError.cancelled {
            throw ZError.cancelled
        } catch {
            errors.append("\(u.lastPathComponent) : \(error.localizedDescription)")
        }
    }
    if outs.isEmpty, let e = errors.first { throw ZError.msg(e) }
    Runner.partialErrors = errors
    return outs
}

@MainActor
func one(_ f: @escaping @MainActor (URL) async throws -> URL) -> @MainActor (URL) async throws -> [URL] {
    { [try await f($0)] }
}
