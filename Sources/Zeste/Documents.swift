import AppKit
import PDFKit

// MARK: - Textes et traitements de texte

@MainActor
enum Docs {
    static let types: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML, "rtf": .rtf, "rtfd": .rtfd, "html": .html, "odt": .openDocument, "doc": .docFormat,
    ]

    static func load(_ u: URL) throws -> NSAttributedString {
        if u.normExt == "md" {
            let s = try String(contentsOf: u, encoding: .utf8)
            let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            if let a = try? AttributedString(markdown: s, options: opts) { return NSAttributedString(a) }
            return NSAttributedString(string: s)
        }
        if u.normExt == "txt" {
            let s = try ((try? String(contentsOf: u, encoding: .utf8)) ?? String(contentsOf: u, encoding: .isoLatin1))
            return NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        return try NSAttributedString(url: u, options: [:], documentAttributes: nil)
    }

    static func write(_ a: NSAttributedString, to out: URL, ext: String) throws {
        let range = NSRange(location: 0, length: a.length)
        switch ext {
        case "txt", "md":
            try a.string.write(to: out, atomically: true, encoding: .utf8)
        case "pdf":
            try pdf(a, to: out)
        case "rtfd":
            let w = try a.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            try w.write(to: out, options: .atomic, originalContentsURL: nil)
        default:
            guard let type = types[ext] else { throw ZError.msg("format \(ext.uppercased()) non pris en charge") }
            let d = try a.data(from: range, documentAttributes: [.documentType: type])
            try d.write(to: out)
        }
    }

    /// Mise en page A4 (marges 2 cm) et impression vers un PDF, sans boîte de dialogue.
    static func pdf(_ a: NSAttributedString, to out: URL) throws {
        let text = NSMutableAttributedString(attributedString: a)
        let full = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.foregroundColor, in: full) { v, r, _ in
            if v == nil { text.addAttribute(.foregroundColor, value: NSColor.black, range: r) }
        }
        let info = NSPrintInfo(dictionary: [NSPrintInfo.AttributeKey.jobSavingURL: out])
        info.jobDisposition = .save
        info.paperSize = NSSize(width: 595, height: 842)
        for m in [\NSPrintInfo.topMargin, \NSPrintInfo.bottomMargin, \NSPrintInfo.leftMargin, \NSPrintInfo.rightMargin] {
            info[keyPath: m] = 56
        }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false

        let width = 595.0 - 112
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        tv.appearance = NSAppearance(named: .aqua)
        tv.backgroundColor = .white
        tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.textStorage?.setAttributedString(text)
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            tv.frame.size.height = max(lm.usedRect(for: tc).height + 20, 100)
        }
        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw ZError.msg("PDF impossible à créer") }
    }

    static func convert(_ u: URL, to ext: String) async throws -> URL {
        let out = Out.url(u, ext: ext)
        let src = u.normExt
        // Word : Pages conserve la mise en page (images, colonnes) bien mieux qu'AppKit.
        if ext == "pdf" && (src == "docx" || src == "doc") {
            try await IWork.export("Pages", u, to: out, as: "PDF")
            return out
        }
        if ext == "pages" || ext == "epub" {
            var docx = u
            var tmp: URL?
            if src != "docx" && src != "doc" {
                let t = Out.temp("docx")
                try write(try load(u), to: t, ext: "docx")
                docx = t; tmp = t
            }
            defer { if let t = tmp { try? FileManager.default.removeItem(at: t) } }
            if ext == "pages" { try await IWork.save("Pages", docx, to: out) }
            else { try await IWork.export("Pages", docx, to: out, as: "EPUB") }
            return out
        }
        try write(try load(u), to: out, ext: ext)
        return out
    }

    /// Fichier .pages : tout passe par Pages.
    static func fromPages(_ u: URL, to ext: String) async throws -> URL {
        let out = Out.url(u, ext: ext)
        let fmt = ["pdf": "PDF", "docx": "Microsoft Word", "epub": "EPUB", "txt": "unformatted text", "rtf": "formatted text"][ext]!
        try await IWork.export("Pages", u, to: out, as: fmt)
        return out
    }
}

// MARK: - PDF

@MainActor
enum PDF {
    static func open(_ u: URL) throws -> PDFDocument {
        guard let d = PDFDocument(url: u) else { throw ZError.msg("PDF illisible") }
        if d.isLocked { throw ZError.msg("PDF protégé par mot de passe") }
        return d
    }

    /// Rendu d'une page à `dpi`, fond blanc, rotation de la page respectée.
    static func render(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let rot = ((page.rotation % 360) + 360) % 360
        var w = box.width, h = box.height
        if rot == 90 || rot == 270 { swap(&w, &h) }
        let s = dpi / 72
        guard let ctx = Img.context(Int(w * s), Int(h * s), alpha: false) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: Int(w * s), height: Int(h * s)))
        ctx.scaleBy(x: s, y: s)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// Toutes les pages en images à 300 dpi ; plusieurs pages vont dans un dossier.
    static func toImages(_ u: URL, ext: String) async throws -> URL {
        let d = try open(u)
        if d.pageCount == 1, let p = d.page(at: 0), let img = render(p, dpi: 300) {
            let out = Out.url(u, ext: ext)
            try await Img.write(img, to: out, ext: ext, quality: 0.92)
            return out
        }
        let dir = try Out.folder(u, suffix: "(pages)")
        let digits = max(2, String(d.pageCount).count)
        for i in 0..<d.pageCount {
            guard let p = d.page(at: i), let img = render(p, dpi: 300) else { continue }
            let n = String(format: "%0\(digits)d", i + 1)
            try await Img.write(img, to: dir.appendingPathComponent("\(u.baseName) \(n).\(ext)"), ext: ext, quality: 0.92)
        }
        return dir
    }

    static func text(_ d: PDFDocument, markdown: Bool) -> String {
        var pages: [String] = []
        for i in 0..<d.pageCount {
            let t = (d.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { pages.append(t) }
        }
        return pages.joined(separator: markdown ? "\n\n---\n\n" : "\n\n")
    }

    static func attributed(_ d: PDFDocument) -> NSAttributedString {
        let all = NSMutableAttributedString()
        for i in 0..<d.pageCount {
            if let a = d.page(at: i)?.attributedString {
                if all.length > 0 { all.append(NSAttributedString(string: "\n\n")) }
                all.append(a)
            }
        }
        return all
    }

    static func convert(_ u: URL, to ext: String) async throws -> URL {
        switch ext {
        case "jpg", "png":
            return try await toImages(u, ext: ext)
        case "txt", "md":
            let out = Out.url(u, ext: ext)
            try text(try open(u), markdown: ext == "md").write(to: out, atomically: true, encoding: .utf8)
            return out
        case "docx":
            let out = Out.url(u, ext: "docx")
            try Docs.write(attributed(try open(u)), to: out, ext: "docx")
            return out
        default: // pages, epub : Word intermédiaire, puis Pages
            let tmp = Out.temp("docx")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try Docs.write(attributed(try open(u)), to: tmp, ext: "docx")
            let out = Out.url(u, ext: ext)
            if ext == "pages" { try await IWork.save("Pages", tmp, to: out) }
            else { try await IWork.export("Pages", tmp, to: out, as: "EPUB") }
            return out
        }
    }

    // MARK: Outils

    static func compress(_ u: URL) throws -> URL {
        let d = try open(u)
        let out = Out.url(u, ext: "pdf", suffix: "compressé")
        guard d.write(to: out, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]) else {
            throw ZError.msg("compression impossible")
        }
        return out
    }

    static func split(_ u: URL) throws -> URL {
        let d = try open(u)
        let dir = try Out.folder(u, suffix: "(pages)")
        let digits = max(2, String(d.pageCount).count)
        for i in 0..<d.pageCount {
            let single = PDFDocument()
            if let p = d.page(at: i)?.copy() as? PDFPage { single.insert(p, at: 0) }
            single.write(to: dir.appendingPathComponent("\(u.baseName) \(String(format: "%0\(digits)d", i + 1)).pdf"))
        }
        return dir
    }

    static func rotate(_ u: URL) throws -> URL {
        let d = try open(u)
        for i in 0..<d.pageCount { if let p = d.page(at: i) { p.rotation = (p.rotation + 90) % 360 } }
        let out = Out.url(u, ext: "pdf", suffix: "pivoté")
        guard d.write(to: out) else { throw ZError.msg("rotation impossible") }
        return out
    }

    /// « 1-3, 5, 8-10 » → pages extraites dans un nouveau PDF.
    static func extract(_ u: URL) throws -> URL {
        let d = try open(u)
        guard let spec = Ask.text(title: "Extraire des pages de « \(u.lastPathComponent) »",
                                  info: "Le PDF compte \(d.pageCount) pages. Pages à garder (ex. : 1-3, 5) :",
                                  initial: "1") else { throw ZError.cancelled }
        var pages: [Int] = []
        for part in spec.split(separator: ",") {
            let bits = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bits.count == 1 { pages.append(bits[0]) }
            if bits.count == 2, bits[0] <= bits[1] { pages += Array(bits[0]...bits[1]) }
        }
        pages = pages.filter { $0 >= 1 && $0 <= d.pageCount }
        guard !pages.isEmpty else { throw ZError.msg("aucune page valide") }
        let out = PDFDocument()
        for n in pages { if let p = d.page(at: n - 1)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) } }
        let url = Out.url(u, ext: "pdf", suffix: "extrait")
        guard out.write(to: url) else { throw ZError.msg("extraction impossible") }
        return url
    }
}

// MARK: - Pages, Keynote, Numbers (pilotés par AppleScript, hors ligne)

@MainActor
enum IWork {
    static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func script(_ app: String, _ input: URL, _ body: String) async throws {
        let s = """
        set inF to POSIX file \(q(input.path))
        tell application "\(app)"
            set d to open inF
            \(body)
            close d saving no
        end tell
        """
        do {
            try await Shell.run("/usr/bin/osascript", ["-e", s], timeout: 300)
        } catch {
            throw ZError.msg("\(app) : \(error.localizedDescription). Autorise Zeste à piloter \(app) (Réglages Système › Confidentialité › Automatisation).")
        }
    }

    static func export(_ app: String, _ input: URL, to out: URL, as fmt: String, props: String? = nil) async throws {
        let extra = props.map { " with properties " + $0 } ?? ""
        try await script(app, input, "export d to (POSIX file \(q(out.path))) as \(fmt)\(extra)")
        guard FileManager.default.fileExists(atPath: out.path) else { throw ZError.msg("\(app) n'a rien exporté") }
    }

    static func save(_ app: String, _ input: URL, to out: URL) async throws {
        try await script(app, input, "save d in (POSIX file \(q(out.path)))")
        guard FileManager.default.fileExists(atPath: out.path) else { throw ZError.msg("\(app) n'a rien enregistré") }
    }

    // Diapositives (Keynote)
    static func slides(_ u: URL, to ext: String) async throws -> URL {
        switch ext {
        case "pdf": let o = Out.url(u, ext: "pdf"); try await export("Keynote", u, to: o, as: "PDF"); return o
        case "pptx": let o = Out.url(u, ext: "pptx"); try await export("Keynote", u, to: o, as: "Microsoft PowerPoint"); return o
        case "key": let o = Out.url(u, ext: "key"); try await save("Keynote", u, to: o); return o
        default:
            let dir = Out.url(u, ext: "", suffix: "(diapositives)")
            try await export("Keynote", u, to: dir, as: "slide images", props: "{image format:\(ext == "png" ? "PNG" : "JPEG")}")
            return dir
        }
    }

    // Tableurs (Numbers)
    static func sheet(_ u: URL, to ext: String) async throws -> URL {
        let o = Out.url(u, ext: ext)
        switch ext {
        case "pdf": try await export("Numbers", u, to: o, as: "PDF")
        case "xlsx": try await export("Numbers", u, to: o, as: "Microsoft Excel")
        case "numbers": try await save("Numbers", u, to: o)
        case "csv": try await export("Numbers", u, to: o, as: "CSV")
        default: // tsv : CSV par Numbers, puis tabulations
            let tmp = Out.temp("csv")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try await export("Numbers", u, to: tmp, as: "CSV")
            try Delimited.rewrite(tmp, to: o, from: ",", to: "\t")
        }
        return o
    }
}

// MARK: - CSV / TSV

@MainActor
enum Delimited {
    /// Lecture CSV conforme (guillemets, virgules et retours à la ligne dans les cellules).
    static func parse(_ text: String, sep: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var inQuotes = false
        var it = Array(text).makeIterator()
        var pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let n = it.next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" { inQuotes = true }
            else if c == sep { row.append(field); field = "" }
            else if c == "\n" || c == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
            else if c == "\r" { continue }
            else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func serialize(_ rows: [[String]], sep: String) -> String {
        rows.map { r in
            r.map { f in
                (f.contains(sep) || f.contains("\"") || f.contains("\n")) ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
            }.joined(separator: sep)
        }.joined(separator: "\n") + "\n"
    }

    static func rewrite(_ src: URL, to out: URL, from: Character, to sep: String) throws {
        let text = try ((try? String(contentsOf: src, encoding: .utf8)) ?? String(contentsOf: src, encoding: .isoLatin1))
        try serialize(parse(text, sep: from), sep: sep).write(to: out, atomically: true, encoding: .utf8)
    }

    static func convert(_ u: URL, to ext: String) async throws -> URL {
        let o = Out.url(u, ext: ext)
        let sep: Character = u.ext == "tsv" ? "\t" : ","
        switch ext {
        case "csv": try rewrite(u, to: o, from: sep, to: ",")
        case "tsv": try rewrite(u, to: o, from: sep, to: "\t")
        default: return try await IWork.sheet(u, to: ext)
        }
        return o
    }
}

// MARK: - Sous-titres

@MainActor
enum Subtitles {
    static func read(_ u: URL) throws -> String {
        (try ((try? String(contentsOf: u, encoding: .utf8)) ?? String(contentsOf: u, encoding: .isoLatin1)))
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    static func blocks(_ s: String) -> [[String]] {
        s.components(separatedBy: "\n\n").map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
            .filter { !$0.joined().trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func convert(_ u: URL, to ext: String) throws -> URL {
        let text = try read(u)
        let out = Out.url(u, ext: ext)
        var result = ""
        switch ext {
        case "vtt":
            result = "WEBVTT\n\n"
            for b in blocks(text) {
                let lines = b.filter { Int($0.trimmingCharacters(in: .whitespaces)) == nil || $0.contains("-->") }
                result += lines.map { $0.contains("-->") ? $0.replacingOccurrences(of: ",", with: ".") : $0 }.joined(separator: "\n") + "\n\n"
            }
        case "srt":
            var n = 1
            for b in blocks(text) {
                guard let t = b.firstIndex(where: { $0.contains("-->") }) else { continue }
                let parts = b[t].components(separatedBy: "-->").map { $0.trimmingCharacters(in: .whitespaces) }
                func fix(_ s: String) -> String {
                    var x = String(s.split(separator: " ").first ?? "").replacingOccurrences(of: ".", with: ",")
                    if x.filter({ $0 == ":" }).count == 1 { x = "00:" + x }
                    return x
                }
                let start = fix(parts[0]), end = fix(parts.count > 1 ? parts[1] : parts[0])
                result += "\(n)\n\(start) --> \(end)\n" + b[(t + 1)...].joined(separator: "\n") + "\n\n"
                n += 1
            }
        default: // txt
            var last = ""
            for b in blocks(text) {
                for l in b where !l.contains("-->") && Int(l.trimmingCharacters(in: .whitespaces)) == nil && !l.hasPrefix("WEBVTT") && !l.hasPrefix("NOTE") {
                    let clean = l.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                    if !clean.isEmpty && clean != last { result += clean + "\n"; last = clean }
                }
            }
        }
        try result.write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

// MARK: - Archives

@MainActor
enum Archive {
    static func extract(_ u: URL) async throws -> URL {
        let dest = Out.url(u, ext: "")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try await extract(u, into: dest)
        return dest
    }

    static func extract(_ u: URL, into dest: URL) async throws {
        let name = u.lastPathComponent.lowercased()
        if u.ext == "zip" {
            try await Shell.run("/usr/bin/ditto", ["-x", "-k", u.path, dest.path])
        } else if u.ext == "gz" && !name.hasSuffix(".tar.gz") {
            try await Shell.run("/usr/bin/gunzip", ["-c", u.path], stdoutFile: dest.appendingPathComponent(u.baseName))
        } else {
            // tar de macOS (libarchive) lit aussi le RAR et le 7z.
            try await Shell.run("/usr/bin/tar", ["-xf", u.path, "-C", dest.path])
        }
    }

    /// Plusieurs fichiers : on les rassemble dans un dossier temporaire pour une archive propre.
    static func create(_ urls: [URL], ext: String) async throws -> [URL] {
        let first = urls[0]
        let name = urls.count == 1 ? first.lastPathComponent : "Archive"
        let out = Out.unique(Out.dir(for: first).appendingPathComponent(name).appendingPathExtension(ext))
        let parent = first.deletingLastPathComponent()
        let sameParent = urls.allSatisfy { $0.deletingLastPathComponent().path == parent.path }
        var items = urls.map { $0.lastPathComponent }
        var cwd = parent
        var staging: URL?
        if !sameParent {
            let s = Out.temp("")
            try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
            for u in urls { try FileManager.default.copyItem(at: u, to: s.appendingPathComponent(u.lastPathComponent)) }
            staging = s; cwd = s; items = urls.map { $0.lastPathComponent }
        }
        defer { if let s = staging { try? FileManager.default.removeItem(at: s) } }
        switch ext {
        case "zip":
            if urls.count == 1 {
                try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path])
            } else {
                try await Shell.run("/usr/bin/zip", ["-r", "-q", "-X", out.path] + items, cwd: cwd)
            }
        case "tar":
            try await Shell.run("/usr/bin/tar", ["-cf", out.path, "--exclude", ".DS_Store"] + items, cwd: cwd)
        default: // tar.gz
            try await Shell.run("/usr/bin/tar", ["-czf", out.path, "--exclude", ".DS_Store"] + items, cwd: cwd)
        }
        return [out]
    }

    /// Archive → autre format d'archive : extraction temporaire puis recompression.
    static func repack(_ u: URL, to ext: String) async throws -> URL {
        let tmp = Out.temp("")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await extract(u, into: tmp)
        let items = try FileManager.default.contentsOfDirectory(atPath: tmp.path).filter { $0 != "__MACOSX" && $0 != ".DS_Store" }
        let out = Out.url(u, ext: ext)
        switch ext {
        case "zip": try await Shell.run("/usr/bin/zip", ["-r", "-q", "-X", out.path] + items, cwd: tmp)
        case "tar": try await Shell.run("/usr/bin/tar", ["-cf", out.path] + items, cwd: tmp)
        default: try await Shell.run("/usr/bin/tar", ["-czf", out.path] + items, cwd: tmp)
        }
        return out
    }
}
