import Foundation

/// Ce que propose chaque roue selon les fichiers glissés.
@MainActor
enum Catalog {
    static func options(for urls: [URL], mode: Mode) -> [Option] {
        guard !urls.isEmpty else { return [] }
        switch mode {
        case .actions: return actions
        case .convert: return convert(urls)
        case .tools: return tools(urls)
        }
    }

    // MARK: Convertir

    static func convert(_ urls: [URL]) -> [Option] {
        // Options communes à tous les fichiers, dans l'ordre du premier.
        var common = formats(for: urls[0])
        for u in urls.dropFirst() {
            let ids = Set(formats(for: u).map(\.id))
            common = common.filter { ids.contains($0.id) }
        }
        // On masque le format d'origine quand tous les fichiers y sont déjà.
        let exts = Set(urls.map(\.normExt))
        return common.filter { o in !(exts.count == 1 && o.target == exts.first) }
    }

    static func conv(_ ext: String, _ title: String, _ symbol: String, _ f: @escaping @MainActor (URL, String) async throws -> URL) -> Option {
        Option(id: "to-\(ext)", title: title, symbol: symbol, target: ext) { urls in
            try await each(urls, "Conversion en \(title)") { [try await f($0, ext)] }
        }
    }

    static func formats(for u: URL) -> [Option] {
        switch u.kind {
        case .image:
            return [conv("jpg", "JPG", "photo", Img.convert), conv("png", "PNG", "photo.fill", Img.convert),
                    conv("webp", "WebP", "globe", Img.convert), conv("heic", "HEIC", "camera", Img.convert),
                    conv("avif", "AVIF", "sparkles", Img.convert), conv("tiff", "TIFF", "square.grid.3x3", Img.convert),
                    conv("bmp", "BMP", "square.grid.2x2", Img.convert), conv("pdf", "PDF", "doc.richtext", Img.convert)]
        case .svg:
            return [conv("png", "PNG", "photo.fill", Img.convert), conv("jpg", "JPG", "photo", Img.convert),
                    conv("webp", "WebP", "globe", Img.convert), conv("tiff", "TIFF", "square.grid.3x3", Img.convert),
                    conv("pdf", "PDF", "doc.richtext", Img.convert)]
        case .gif:
            return [conv("mp4", "MP4", "film", Media.convert), conv("webm", "WebM", "globe", Media.convert),
                    conv("mov", "MOV", "film.stack", Media.convert), conv("webp", "WebP", "sparkles.rectangle.stack", Media.convert),
                    conv("png", "PNG", "photo.fill", Img.convert), conv("jpg", "JPG", "photo", Img.convert)]
        case .video:
            return [conv("mp4", "MP4", "film", Media.convert), conv("mov", "MOV", "film.stack", Media.convert),
                    conv("mkv", "MKV", "shippingbox", Media.convert), conv("webm", "WebM", "globe", Media.convert),
                    conv("avi", "AVI", "tv", Media.convert), conv("wmv", "WMV", "pc", Media.convert),
                    conv("gif", "GIF", "sparkles.rectangle.stack", Media.convert), conv("mp3", "MP3", "music.note", Media.convert)]
        case .audio:
            return [conv("mp3", "MP3", "music.note", Media.convert), conv("m4a", "M4A", "applelogo", Media.convert),
                    conv("wav", "WAV", "waveform", Media.convert), conv("flac", "FLAC", "waveform.path.ecg", Media.convert),
                    conv("ogg", "OGG", "circle.hexagongrid", Media.convert), conv("opus", "Opus", "dot.radiowaves.right", Media.convert),
                    conv("aiff", "AIFF", "hifispeaker", Media.convert), conv("wma", "WMA", "pc", Media.convert)]
        case .pdf:
            return [conv("jpg", "JPG", "photo", PDF.convert), conv("png", "PNG", "photo.fill", PDF.convert),
                    conv("docx", "Word", "doc.text", PDF.convert), conv("pages", "Pages", "doc.richtext", PDF.convert),
                    conv("epub", "EPUB", "book", PDF.convert), conv("txt", "Texte", "text.alignleft", PDF.convert),
                    conv("md", "Markdown", "number", PDF.convert)]
        case .document:
            return [conv("docx", "Word", "doc.text", Docs.convert), conv("pdf", "PDF", "doc.richtext", Docs.convert),
                    conv("pages", "Pages", "doc.richtext.fill", Docs.convert), conv("epub", "EPUB", "book", Docs.convert),
                    conv("rtf", "RTF", "textformat", Docs.convert), conv("html", "HTML", "chevron.left.forwardslash.chevron.right", Docs.convert),
                    conv("txt", "Texte", "text.alignleft", Docs.convert), conv("md", "Markdown", "number", Docs.convert),
                    conv("odt", "ODT", "doc", Docs.convert)]
        case .pages:
            return [conv("pdf", "PDF", "doc.richtext", Docs.fromPages), conv("docx", "Word", "doc.text", Docs.fromPages),
                    conv("epub", "EPUB", "book", Docs.fromPages), conv("txt", "Texte", "text.alignleft", Docs.fromPages),
                    conv("rtf", "RTF", "textformat", Docs.fromPages)]
        case .slides:
            return [conv("pdf", "PDF", "doc.richtext", IWork.slides), conv("pptx", "PowerPoint", "rectangle.on.rectangle", IWork.slides),
                    conv("key", "Keynote", "play.rectangle", IWork.slides), conv("jpg", "Images JPG", "photo.on.rectangle", IWork.slides),
                    conv("png", "Images PNG", "photo.fill.on.rectangle.fill", IWork.slides)]
        case .sheet:
            return [conv("xlsx", "Excel", "tablecells", IWork.sheet), conv("csv", "CSV", "list.bullet.rectangle", IWork.sheet),
                    conv("tsv", "TSV", "list.bullet.indent", IWork.sheet), conv("pdf", "PDF", "doc.richtext", IWork.sheet),
                    conv("numbers", "Numbers", "chart.bar.doc.horizontal", IWork.sheet)]
        case .delimited:
            return [conv("csv", "CSV", "list.bullet.rectangle", Delimited.convert), conv("tsv", "TSV", "list.bullet.indent", Delimited.convert),
                    conv("xlsx", "Excel", "tablecells", Delimited.convert), conv("numbers", "Numbers", "chart.bar.doc.horizontal", Delimited.convert),
                    conv("pdf", "PDF", "doc.richtext", Delimited.convert)]
        case .subtitle:
            return [conv("srt", "SRT", "captions.bubble", { try Subtitles.convert($0, to: $1) }),
                    conv("vtt", "VTT", "captions.bubble.fill", { try Subtitles.convert($0, to: $1) }),
                    conv("txt", "Texte", "text.alignleft", { try Subtitles.convert($0, to: $1) })]
        case .archive:
            return [Option(id: "extract", title: "Extraire", symbol: "arrow.up.bin") { urls in
                        try await each(urls, "Extraction") { [try await Archive.extract($0)] }
                    },
                    conv("zip", "ZIP", "doc.zipper", Archive.repack), conv("tar", "TAR", "archivebox", Archive.repack),
                    conv("tgz", "TAR.GZ", "archivebox.fill", Archive.repack)]
        case .folder:
            return archiveCreate
        case .other:
            return []
        }
    }

    static let archiveCreate: [Option] = [
        Option(id: "make-zip", title: "ZIP", symbol: "doc.zipper", target: "zip") { try await Archive.create($0, ext: "zip") },
        Option(id: "make-tar", title: "TAR", symbol: "archivebox", target: "tar") { try await Archive.create($0, ext: "tar") },
        Option(id: "make-tgz", title: "TAR.GZ", symbol: "archivebox.fill", target: "tgz") { try await Archive.create($0, ext: "tar.gz") },
    ]

    // MARK: Outils

    static func tool(_ id: String, _ title: String, _ symbol: String, _ f: @escaping @MainActor (URL) async throws -> [URL]) -> Option {
        Option(id: id, title: title, symbol: symbol) { urls in try await each(urls, title, f) }
    }

    static let zip = Option(id: "zip", title: "ZIP", symbol: "doc.zipper") { try await Archive.create($0, ext: "zip") }

    static func tools(_ urls: [URL]) -> [Option] {
        let kinds = Set(urls.map(\.kind))
        let many = urls.count > 1
        if kinds.count > 1 {
            // Sélection mixte : seules les images et les PDF se rassemblent.
            if kinds.isSubset(of: [.image, .svg, .pdf]) && many {
                return [Option(id: "merge-pdf", title: "En un PDF", symbol: "square.stack.3d.up", run: Img.mergePDF), zip]
            }
            return [zip]
        }
        switch kinds.first! {
        case .image, .svg:
            var t = [tool("img-compress", "Compresser", "arrow.down.right.and.arrow.up.left", one(Img.compress)),
                     tool("img-half", "50 %", "rectangle.compress.vertical", one { try await Img.resize($0, factor: 0.5, suffix: "50 %") }),
                     tool("img-1920", "1920 px", "rectangle.and.arrow.up.right.and.arrow.down.left", one { try await Img.resize($0, maxSide: 1920, suffix: "1920") }),
                     tool("img-square", "Carré", "crop", one { try await Img.transform($0, suffix: "carré", Img.squareCrop) }),
                     tool("img-rotate", "Pivoter", "rotate.right", one { try await Img.transform($0, suffix: "pivotée", Img.rotateRight) }),
                     tool("img-flip", "Miroir", "arrow.left.and.right.righttriangle.left.righttriangle.right", one { try await Img.transform($0, suffix: "miroir", Img.flip) }),
                     tool("img-strip", "Sans EXIF", "eye.slash", one(Img.stripMetadata)),
                     tool("img-favicon", "Favicon", "app.badge", one { try Img.favicon($0) })]
            if many { t.insert(Option(id: "merge-pdf", title: "En un PDF", symbol: "square.stack.3d.up", run: Img.mergePDF), at: 0) }
            return t + [zip]
        case .gif:
            return [tool("gif-compress", "Compresser", "arrow.down.right.and.arrow.up.left", one(Media.compressGIF)),
                    tool("trim", "Couper", "scissors", one(Media.trim)),
                    tool("speed", "Accélérer ×2", "hare", one(Media.speed2x)),
                    tool("frame", "Capture", "camera.viewfinder", one(Media.frame)), zip]
        case .video:
            var t = [tool("vid-compress", "Compresser", "arrow.down.right.and.arrow.up.left", one(Media.compressVideo)),
                     tool("vid-720", "720p", "rectangle.compress.vertical", one(Media.to720)),
                     tool("trim", "Couper", "scissors", one(Media.trim)),
                     tool("split", "Découper", "square.split.2x1", Media.split),
                     tool("mute", "Muet", "speaker.slash", one(Media.mute)),
                     tool("vid-rotate", "Pivoter", "rotate.right", one(Media.rotateVideo)),
                     tool("speed", "Accélérer ×2", "hare", one(Media.speed2x)),
                     tool("frame", "Capture", "camera.viewfinder", one(Media.frame))]
            if many { t.insert(Option(id: "merge-video", title: "Fusionner", symbol: "square.stack.3d.up", run: Media.mergeVideos), at: 0) }
            return t + [zip]
        case .audio:
            var t = [tool("aud-compress", "Compresser", "arrow.down.right.and.arrow.up.left", one(Media.compressAudio)),
                     tool("trim", "Couper", "scissors", one(Media.trim)),
                     tool("split", "Découper", "square.split.2x1", Media.split),
                     tool("normalize", "Normaliser", "speaker.wave.3", one(Media.normalize)),
                     tool("mono", "Mono", "speaker.wave.1", one(Media.mono))]
            if many { t.insert(Option(id: "merge-audio", title: "Fusionner", symbol: "square.stack.3d.up", run: Media.mergeAudio), at: 0) }
            return t + [zip]
        case .pdf:
            var t = [tool("pdf-compress", "Compresser", "arrow.down.right.and.arrow.up.left", one { try PDF.compress($0) }),
                     tool("pdf-split", "Séparer", "square.split.2x1", one { try PDF.split($0) }),
                     tool("pdf-extract", "Extraire", "doc.on.doc", one { try PDF.extract($0) }),
                     tool("pdf-rotate", "Pivoter", "rotate.right", one { try PDF.rotate($0) })]
            if many { t.insert(Option(id: "merge-pdf", title: "Fusionner", symbol: "square.stack.3d.up", run: Img.mergePDF), at: 0) }
            return t + [zip]
        default:
            return [zip]
        }
    }

    // MARK: Actions

    static let actions: [Option] = [
        Option(id: "airdrop", title: "AirDrop", symbol: "dot.radiowaves.left.and.right", done: { _ in "AirDrop ouvert" }, run: Actions.airdrop),
        Option(id: "float", title: "Flotter", symbol: "pin", done: { n in n > 1 ? "\(n) fenêtres flottantes" : "Fenêtre flottante" }, run: Actions.float),
        Option(id: "copy", title: "Copier", symbol: "doc.on.doc", done: { n in n > 1 ? "\(n) fichiers copiés" : "Fichier copié" }, run: Actions.copy),
        Option(id: "move", title: "Déplacer", symbol: "folder", done: { n in n > 1 ? "\(n) éléments déplacés" : "Déplacé" }, run: Actions.move),
        Option(id: "path", title: "Chemin", symbol: "link", done: { n in n > 1 ? "\(n) chemins copiés" : "Chemin copié" }, run: Actions.copyPath),
        Option(id: "terminal", title: "Terminal", symbol: "terminal", done: { _ in "Terminal ouvert" }, run: Actions.terminal),
    ]
}
