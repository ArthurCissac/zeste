import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Images : conversions et outils, avec ImageIO (natif) et cwebp pour le WebP.
@MainActor
enum Img {
    static let types: [String: String] = [
        "jpg": "public.jpeg", "png": "public.png", "heic": "public.heic", "avif": "public.avif",
        "tiff": "public.tiff", "bmp": "com.microsoft.bmp", "gif": "com.compuserve.gif",
    ]
    static let lossy: Set<String> = ["jpg", "heic", "avif", "webp"]

    // MARK: Lecture

    /// Image orientée (EXIF appliqué) et ses métadonnées, orientation remise à 1.
    static func load(_ url: URL, maxPixel: Int? = nil) throws -> (CGImage, [CFString: Any]) {
        if url.ext == "svg" { return (try svg(url, maxPixel: maxPixel ?? 2048), [:]) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ZError.msg("image illisible")
        }
        var meta = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = meta[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = meta[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel ?? max(w, h, 1),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ZError.msg("image illisible")
        }
        meta[kCGImagePropertyOrientation] = 1
        if var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }
        meta[kCGImagePropertyPixelWidth] = nil
        meta[kCGImagePropertyPixelHeight] = nil
        return (img, meta)
    }

    static func size(_ url: URL) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (0, 0) }
        var w = p[kCGImagePropertyPixelWidth] as? Int ?? 0, h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let o = p[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        return (w, h)
    }

    /// SVG rendu en bitmap : NSImage sait lire le SVG, sinon Quick Look prend le relais.
    static func svg(_ url: URL, maxPixel: Int) throws -> CGImage {
        if let ns = NSImage(contentsOf: url), ns.size.width > 0 {
            let scale = CGFloat(maxPixel) / max(ns.size.width, ns.size.height)
            let w = Int(ns.size.width * scale), h = Int(ns.size.height * scale)
            guard let ctx = context(w, h, alpha: true) else { throw ZError.msg("SVG illisible") }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ns.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            if let img = ctx.makeImage() { return img }
        }
        let dir = Out.temp("")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        task.arguments = ["-t", "-s", String(maxPixel), "-o", dir.path, url.path]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        let png = dir.appendingPathComponent(url.lastPathComponent + ".png")
        guard let src = CGImageSourceCreateWithURL(png as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ZError.msg("SVG illisible") }
        return img
    }

    // MARK: Écriture

    static func context(_ w: Int, _ h: Int, alpha: Bool) -> CGContext? {
        CGContext(data: nil, width: max(w, 1), height: max(h, 1), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    static func hasAlpha(_ img: CGImage) -> Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(img.alphaInfo)
    }

    /// Fond blanc sous la transparence : sans ça, un PNG transparent devient noir en JPEG.
    static func flatten(_ img: CGImage) -> CGImage {
        guard hasAlpha(img), let ctx = context(img.width, img.height, alpha: false) else { return img }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }

    static func write(_ img: CGImage, meta: [CFString: Any] = [:], to out: URL, ext: String, quality: Double? = nil) async throws {
        if ext == "webp" { return try await webp(img, to: out, quality: quality ?? Prefs.quality) }
        if ext == "pdf" { return try pdf(images: [img], to: out) }
        guard let type = types[ext],
              let dest = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil) else {
            throw ZError.msg("format \(ext.uppercased()) non pris en charge")
        }
        let image = (ext == "jpg" || ext == "bmp") ? flatten(img) : img
        var p = meta
        if lossy.contains(ext) { p[kCGImageDestinationLossyCompressionQuality] = quality ?? Prefs.quality }
        CGImageDestinationAddImage(dest, image, p as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ZError.msg("écriture \(ext.uppercased()) impossible") }
    }

    static func webp(_ img: CGImage, to out: URL, quality: Double) async throws {
        let tmp = Out.temp("png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        let q = String(Int((quality * 100).rounded()))
        if let cwebp = Shell.find("cwebp") {
            try await Shell.run(cwebp, ["-quiet", "-q", q, "-metadata", "none", tmp.path, "-o", out.path])
        } else {
            try await Shell.run(try Shell.ffmpeg(), ["-hide_banner", "-nostdin", "-y", "-i", tmp.path, "-c:v", "libwebp", "-quality", q, out.path])
        }
    }

    /// Une page par image ; taille de page calée sur 150 dpi pour rester lisible à l'impression.
    static func pdf(images: [CGImage], to out: URL) throws {
        let doc = PDFDocument()
        for img in images {
            let ns = NSImage(cgImage: img, size: NSSize(width: CGFloat(img.width) * 72 / 150, height: CGFloat(img.height) * 72 / 150))
            if let page = PDFPage(image: ns) { doc.insert(page, at: doc.pageCount) }
        }
        guard doc.pageCount > 0, doc.write(to: out) else { throw ZError.msg("PDF impossible à créer") }
    }

    // MARK: Conversions

    static func convert(_ url: URL, to ext: String) async throws -> URL {
        let out = Out.url(url, ext: ext)
        if ext == "pdf" {
            let (img, _) = try load(url)
            try pdf(images: [img], to: out)
            return out
        }
        let (img, meta) = try load(url)
        try await write(img, meta: meta, to: out, ext: ext)
        return out
    }

    /// Images et PDF rassemblés dans un seul PDF, dans l'ordre de la sélection.
    static func mergePDF(_ urls: [URL]) async throws -> [URL] {
        let doc = PDFDocument()
        for u in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            if u.kind == .pdf, let d = PDFDocument(url: u) {
                for i in 0..<d.pageCount { if let p = d.page(at: i)?.copy() as? PDFPage { doc.insert(p, at: doc.pageCount) } }
            } else {
                let (img, _) = try load(u)
                let ns = NSImage(cgImage: img, size: NSSize(width: CGFloat(img.width) * 72 / 150, height: CGFloat(img.height) * 72 / 150))
                if let p = PDFPage(image: ns) { doc.insert(p, at: doc.pageCount) }
            }
        }
        let out = Out.unique(Out.dir(for: urls[0]).appendingPathComponent("Fusion.pdf"))
        guard doc.pageCount > 0, doc.write(to: out) else { throw ZError.msg("fusion impossible") }
        return [out]
    }

    // MARK: Outils

    /// Format d'écriture « identique » : le SVG et les formats inconnus repartent en PNG.
    static func sameExt(_ url: URL) -> String {
        let e = url.normExt
        return (types[e] != nil || e == "webp") ? e : "png"
    }

    static func compress(_ url: URL) async throws -> URL {
        let e = sameExt(url)
        if e == "png" {
            // PNG : réduction à 256 couleurs (comme pngquant), transparence conservée.
            let out = Out.url(url, ext: "png", suffix: "compressé")
            try await Shell.run(try Shell.ffmpeg(), ["-hide_banner", "-nostdin", "-y", "-i", url.path,
                "-vf", "split[a][b];[a]palettegen=max_colors=256:reserve_transparent=1[p];[b][p]paletteuse=dither=sierra2_4a",
                "-frames:v", "1", out.path])
            return out
        }
        let target = ["jpg", "heic", "avif", "webp"].contains(e) ? e : "jpg"
        let out = Out.url(url, ext: target, suffix: "compressé")
        let (img, meta) = try load(url)
        try await write(img, meta: meta, to: out, ext: target, quality: min(0.6, Prefs.quality))
        return out
    }

    static func resize(_ url: URL, maxSide: Int? = nil, factor: Double? = nil, suffix: String) async throws -> URL {
        let (w, h) = size(url)
        var target = max(w, h)
        if let f = factor { target = Int(Double(target) * f) }
        if let m = maxSide { target = min(target, m) }
        let e = sameExt(url)
        let out = Out.url(url, ext: e, suffix: suffix)
        let (img, meta) = try load(url, maxPixel: max(target, 1))
        try await write(img, meta: meta, to: out, ext: e)
        return out
    }

    static func transform(_ url: URL, suffix: String, _ draw: (CGImage) -> CGImage?) async throws -> URL {
        let (img, meta) = try load(url)
        guard let res = draw(img) else { throw ZError.msg("transformation impossible") }
        let e = sameExt(url)
        let out = Out.url(url, ext: e, suffix: suffix)
        try await write(res, meta: meta, to: out, ext: e)
        return out
    }

    static func squareCrop(_ img: CGImage) -> CGImage? {
        let s = min(img.width, img.height)
        return img.cropping(to: CGRect(x: (img.width - s) / 2, y: (img.height - s) / 2, width: s, height: s))
    }

    static func rotateRight(_ img: CGImage) -> CGImage? {
        guard let ctx = context(img.height, img.width, alpha: true) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(img.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    static func flip(_ img: CGImage) -> CGImage? {
        guard let ctx = context(img.width, img.height, alpha: true) else { return nil }
        ctx.translateBy(x: CGFloat(img.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    /// Réécrit l'image sans EXIF, GPS ni IPTC (l'orientation est appliquée aux pixels).
    static func stripMetadata(_ url: URL) async throws -> URL {
        let (img, _) = try load(url)
        let e = sameExt(url)
        let out = Out.url(url, ext: e, suffix: "sans métadonnées")
        try await write(img, meta: [:], to: out, ext: e)
        return out
    }

    /// Favicon multi-tailles (16, 32, 48, 256 px), recadré au carré.
    static func favicon(_ url: URL) throws -> URL {
        let (big, _) = try load(url, maxPixel: 1024)
        guard let square = squareCrop(big) else { throw ZError.msg("favicon impossible") }
        let out = Out.url(url, ext: "ico", suffix: "favicon")
        let sizes = [16, 32, 48, 256]
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "com.microsoft.ico" as CFString, sizes.count, nil) else {
            throw ZError.msg("favicon impossible")
        }
        for s in sizes {
            guard let ctx = context(s, s, alpha: true) else { continue }
            ctx.interpolationQuality = .high
            ctx.draw(square, in: CGRect(x: 0, y: 0, width: s, height: s))
            if let img = ctx.makeImage() { CGImageDestinationAddImage(dest, img, nil) }
        }
        guard CGImageDestinationFinalize(dest) else { throw ZError.msg("favicon impossible") }
        return out
    }
}
