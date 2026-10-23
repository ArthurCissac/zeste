import AppKit
import AVFoundation
import PDFKit
import Speech
import Vision

// MARK: - Formats réseaux sociaux

@MainActor
enum Social {
    struct Format {
        let id: String, title: String, symbol: String, w: Int, h: Int, suffix: String
    }

    static let story = Format(id: "story", title: "Story 9:16", symbol: "rectangle.portrait", w: 1080, h: 1920, suffix: "story")
    static let post = Format(id: "post", title: "Post 4:5", symbol: "rectangle.portrait.on.rectangle.portrait", w: 1080, h: 1350, suffix: "post")
    static let square = Format(id: "square", title: "Carré 1:1", symbol: "square", w: 1080, h: 1080, suffix: "carré 1080")
    static let wide = Format(id: "wide", title: "YouTube 16:9", symbol: "rectangle", w: 1920, h: 1080, suffix: "16-9")
    static let all = [story, post, square, wide]

    /// Image recadrée au centre pour remplir exactement le format, puis redimensionnée.
    static func image(_ u: URL, _ f: Format) async throws -> URL {
        let (img, meta) = try Img.load(u)
        let target = CGFloat(f.w) / CGFloat(f.h)
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        var crop = CGRect(x: 0, y: 0, width: iw, height: ih)
        if iw / ih > target { crop.size.width = ih * target; crop.origin.x = (iw - crop.width) / 2 }
        else { crop.size.height = iw / target; crop.origin.y = (ih - crop.height) / 2 }
        guard let cut = img.cropping(to: crop.integral), let ctx = Img.context(f.w, f.h, alpha: Img.hasAlpha(img)) else {
            throw ZError.msg("recadrage impossible")
        }
        ctx.interpolationQuality = .high
        ctx.draw(cut, in: CGRect(x: 0, y: 0, width: f.w, height: f.h))
        guard let res = ctx.makeImage() else { throw ZError.msg("recadrage impossible") }
        let ext = Img.hasAlpha(img) ? "png" : "jpg"
        let out = Out.url(u, ext: ext, suffix: f.suffix)
        try await Img.write(res, meta: meta, to: out, ext: ext, quality: 0.9)
        return out
    }

    /// Vidéo recadrée au centre pour remplir le format.
    static func video(_ u: URL, _ f: Format) async throws -> URL {
        let out = Out.url(u, ext: "mp4", suffix: f.suffix)
        try await Media.ff(["-i", u.path, "-map", "0:v:0", "-map", "0:a?"]
            + Media.encode("mp4", vf: "scale=\(f.w):\(f.h):force_original_aspect_ratio=increase,crop=\(f.w):\(f.h),setsar=1") + [out.path])
        return out
    }

    /// Vidéo entière, centrée sur un fond flou de la même vidéo (format vertical sans rien couper).
    static func blurred(_ u: URL, _ f: Format) async throws -> URL {
        let out = Out.url(u, ext: "mp4", suffix: f.suffix + " fond flou")
        let w = f.w, h = f.h
        let graph = "[0:v]scale=\(w / 4):\(h / 4):force_original_aspect_ratio=increase,crop=\(w / 4):\(h / 4),gblur=sigma=12,scale=\(w):\(h),eq=brightness=-0.08[bg];"
            + "[0:v]scale=\(w):\(h):force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2[fg];"
            + "[bg][fg]overlay=(W-w)/2:(H-h)/2,setsar=1,format=yuv420p[v]"
        try await Media.ff(["-i", u.path, "-filter_complex", graph, "-map", "[v]", "-map", "0:a?"]
            + Media.codecOnly("mp4") + [out.path])
        return out
    }
}

// MARK: - Sous-titres automatiques (reconnaissance vocale sur le Mac)

@MainActor
enum AutoSubs {
    struct Word { let text: String; let start: Double; let end: Double }
    struct Cue { let start: Double; let end: Double; let text: String }

    static func authorize() async throws {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw ZError.msg("Autorise la reconnaissance vocale : Réglages Système › Confidentialité et sécurité › Reconnaissance vocale")
        }
    }

    /// Transcription mot par mot, horodatée. L'audio est découpé en tranches de 50 s :
    /// la reconnaissance sur l'appareil perd le début des fichiers trop longs.
    static func words(_ u: URL) async throws -> [Word] {
        try await authorize()
        let locale = Locale(identifier: Prefs.speechLang)
        guard let rec = SFSpeechRecognizer(locale: locale) else { throw ZError.msg("langue non prise en charge") }
        guard rec.supportsOnDeviceRecognition else {
            throw ZError.msg("Transcription hors ligne indisponible : active la Dictée (Réglages Système › Clavier) pour télécharger la langue")
        }
        let dir = Out.temp("")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let slice = 50.0
        try await Media.ff(["-i", u.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
                            "-f", "segment", "-segment_time", String(slice), dir.appendingPathComponent("p%04d.wav").path])
        let parts = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".wav") }.sorted()
        var all: [Word] = []
        for (i, p) in parts.enumerated() {
            if parts.count > 1 { HUD.shared.show("Transcription \(i + 1)/\(parts.count)…", spinning: true) }
            let offset = Double(i) * slice
            let ws = try await recognize(dir.appendingPathComponent(p), rec)
            all += ws.map { Word(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
        }
        guard !all.isEmpty else { throw ZError.msg("aucune parole détectée") }
        return all
    }

    private static func recognize(_ wav: URL, _ rec: SFSpeechRecognizer) async throws -> [Word] {
        let req = SFSpeechURLRecognitionRequest(url: wav)
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            rec.recognitionTask(with: req) { result, error in
                guard !finished else { return }
                if let r = result, r.isFinal {
                    finished = true
                    cont.resume(returning: r.bestTranscription.segments.map {
                        Word(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                    })
                } else if let error {
                    finished = true
                    // Tranche silencieuse : pas une erreur, juste rien à écrire.
                    let ns = error as NSError
                    if ns.code == 1110 || ns.code == 203 { cont.resume(returning: []) }
                    else { cont.resume(throwing: ZError.msg("transcription : \(error.localizedDescription)")) }
                }
            }
        }
    }

    /// Phrases courtes, lisibles en vidéo verticale : 36 caractères ou 3 s au plus, coupure aux pauses.
    static func cues(_ words: [Word]) -> [Cue] {
        var out: [Cue] = []
        var cur: [Word] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            out.append(Cue(start: f.start, end: max(l.end, f.start + 0.7), text: cur.map(\.text).joined(separator: " ")))
            cur = []
        }
        for w in words {
            if let l = cur.last, let f = cur.first {
                let len = (cur.map(\.text) + [w.text]).joined(separator: " ").count
                if w.start - l.end > 0.6 || len > 36 || w.end - f.start > 3.2 || ".!?".contains(l.text.last ?? " ") { flush() }
            }
            cur.append(w)
        }
        flush()
        // Pas de chevauchement entre deux sous-titres.
        for i in out.indices.dropLast() where out[i].end > out[i + 1].start {
            out[i] = Cue(start: out[i].start, end: out[i + 1].start - 0.02, text: out[i].text)
        }
        return out
    }

    static func srt(_ cues: [Cue]) -> String {
        func t(_ s: Double) -> String {
            let ms = Int((s * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return cues.enumerated().map { "\($0.offset + 1)\n\(t($0.element.start)) --> \(t($0.element.end))\n\($0.element.text)\n" }
            .joined(separator: "\n")
    }

    static func toSRT(_ u: URL) async throws -> URL {
        let out = Out.url(u, ext: "srt")
        try srt(cues(try await words(u))).write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func toText(_ u: URL) async throws -> URL {
        let out = Out.url(u, ext: "txt", suffix: "transcription")
        let text = cues(try await words(u)).map(\.text).joined(separator: " ")
            .replacingOccurrences(of: ". ", with: ".\n")
        try text.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// Sous-titres incrustés dans l'image (style réseaux sociaux : blanc gras, contour noir).
    static func burn(_ u: URL) async throws -> URL {
        let list = cues(try await words(u))
        HUD.shared.show("Incrustation des sous-titres…", spinning: true)
        let asset = AVURLAsset(url: u)
        guard let vt = try await asset.loadTracks(withMediaType: .video).first else { throw ZError.msg("pas de piste vidéo") }
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)

        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ZError.msg("composition impossible")
        }
        try cv.insertTimeRange(range, of: vt, at: .zero)
        if let at = try await asset.loadTracks(withMediaType: .audio).first,
           let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try ca.insertTimeRange(range, of: at, at: .zero)
        }

        let natural = try await vt.load(.naturalSize)
        let transform = try await vt.load(.preferredTransform)
        let fps = try await vt.load(.nominalFrameRate)
        let r = CGRect(origin: .zero, size: natural).applying(transform)
        let size = CGSize(width: abs(r.width), height: abs(r.height))

        let vc = AVMutableVideoComposition()
        vc.renderSize = size
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps > 1 ? fps.rounded() : 30))
        let instr = AVMutableVideoCompositionInstruction()
        instr.timeRange = range
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: cv)
        li.setTransform(transform, at: .zero)
        instr.layerInstructions = [li]
        vc.instructions = [instr]

        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)
        let fontSize = min(size.width, size.height) * 0.07
        let boxW = size.width * 0.86
        for c in list {
            // Sur macOS, un CATextLayer n'est pas dessiné à l'export : chaque sous-titre devient une image.
            guard let img = caption(c.text, fontSize: fontSize, width: boxW) else { continue }
            let layer = CALayer()
            layer.contents = img
            let w = CGFloat(img.width) / 2, h = CGFloat(img.height) / 2
            layer.frame = CGRect(x: (size.width - w) / 2, y: size.height * 0.14, width: w, height: h)
            layer.opacity = 0
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.beginTime = c.start <= 0 ? AVCoreAnimationBeginTimeAtZero : c.start
            show.duration = max(0.1, c.end - c.start)
            // AVFoundation évalue les animations à l'export : elles ne doivent jamais être retirées.
            show.isRemovedOnCompletion = false
            show.fillMode = .removed
            layer.add(show, forKey: "show")
            parent.addSublayer(layer)
        }
        vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)

        let out = Out.url(u, ext: "mp4", suffix: "sous-titrée")
        guard let exp = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw ZError.msg("export impossible")
        }
        exp.videoComposition = vc
        exp.outputURL = out
        exp.outputFileType = .mp4
        exp.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in exp.exportAsynchronously { c.resume() } }
        guard exp.status == .completed else { throw ZError.msg("export : \(exp.error?.localizedDescription ?? "échec")") }
        return out
    }

    /// Texte blanc très gras, contour et ombre noirs, centré, rendu en image (×2 pour la netteté).
    static func caption(_ text: String, fontSize: CGFloat, width: CGFloat) -> CGImage? {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let font = NSFont.systemFont(ofSize: fontSize * 2, weight: .heavy)
        let fill: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: para]
        var stroke = fill
        stroke[.strokeColor] = NSColor.black
        stroke[.strokeWidth] = 9.0
        let w = width * 2
        let bound = (text as NSString).boundingRect(with: NSSize(width: w - 40, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin], attributes: fill)
        let h = ceil(bound.height) + 40
        guard let ctx = Img.context(Int(w), Int(h), alpha: true) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let rect = NSRect(x: 20, y: 20, width: w - 40, height: h - 40)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.7)
        shadow.shadowBlurRadius = fontSize * 0.3
        shadow.set()
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: stroke)
        NSShadow().set()
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: fill)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

// MARK: - Texte et QR codes (Vision, sur le Mac)

@MainActor
enum Reader {
    static func ocr(_ img: CGImage) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["fr-FR", "en-US"]
        try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func images(_ u: URL) throws -> [CGImage] {
        if u.kind == .pdf {
            let d = try PDF.open(u)
            return (0..<d.pageCount).compactMap { d.page(at: $0).flatMap { PDF.render($0, dpi: 200) } }
        }
        return [try Img.load(u, maxPixel: 4000).0]
    }

    /// Texte de l'image ou du PDF (couche texte si elle existe, sinon reconnaissance), copié dans le presse-papiers.
    static func text(_ urls: [URL]) async throws -> [URL] {
        var parts: [String] = []
        for u in urls {
            if u.kind == .pdf, let d = PDFDocument(url: u), let s = d.string, s.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 {
                parts.append(s)
                continue
            }
            for img in try images(u) {
                let t = try ocr(img)
                if !t.isEmpty { parts.append(t) }
            }
        }
        let text = parts.joined(separator: "\n\n")
        guard !text.isEmpty else { throw ZError.msg("aucun texte trouvé") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Runner.note = "Texte copié (\(text.count) caractères)"
        return []
    }

    static func qr(_ urls: [URL]) async throws -> [URL] {
        var found: [String] = []
        for u in urls {
            for img in try images(u) {
                let req = VNDetectBarcodesRequest()
                try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
                found += (req.results ?? []).compactMap(\.payloadStringValue)
            }
        }
        guard !found.isEmpty else { throw ZError.msg("aucun QR code trouvé") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(found.joined(separator: "\n"), forType: .string)
        let first = found[0].count > 60 ? String(found[0].prefix(60)) + "…" : found[0]
        Runner.note = "Copié : \(first)" + (found.count > 1 ? " (+\(found.count - 1))" : "")
        return []
    }
}

// MARK: - Compression à une taille cible

@MainActor
enum Target {
    /// « 16 », « 16 Mo », « 500 Ko », « 1,5 Mo » → octets.
    static func parse(_ s: String) -> Int64? {
        let t = s.lowercased().replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        let num = Double(t.filter { "0123456789.".contains($0) }) ?? 0
        guard num > 0 else { return nil }
        let kilo = t.contains("k")
        return Int64(num * (kilo ? 1000 : 1_000_000))
    }

    static func ask(_ u: URL, initial: String) throws -> Int64 {
        guard let s = Ask.text(title: "Compresser « \(u.lastPathComponent) »", info: "Taille maximale (ex. : 16 Mo, 500 Ko) :", initial: initial),
              let b = parse(s) else { throw ZError.cancelled }
        return b
    }

    static func size(_ u: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    static func label(_ b: Int64) -> String {
        if b >= 1_000_000 {
            let mb = Double(b) / 1_000_000
            return mb == mb.rounded() ? "\(Int(mb)) Mo" : String(format: "%.1f Mo", mb).replacingOccurrences(of: ".", with: ",")
        }
        return "\(b / 1000) Ko"
    }

    static func video(_ u: URL, bytes: Int64) async throws -> URL {
        let d = await Media.duration(u)
        guard d > 0 else { throw ZError.msg("durée illisible") }
        let audioK = 96.0
        var videoK = max(120, Double(bytes) * 8 / 1000 / d * 0.9 - audioK)
        let out = Out.url(u, ext: "mp4", suffix: label(bytes))
        for _ in 0..<3 {
            // Débit faible : on réduit aussi la définition, sinon l'image se dégrade en blocs.
            let maxH = videoK < 600 ? 480 : videoK < 1400 ? 720 : videoK < 3500 ? 1080 : 2160
            try? FileManager.default.removeItem(at: out)
            try await Media.ff(["-i", u.path, "-map", "0:v:0", "-map", "0:a?",
                                "-vf", "scale=-2:'min(\(maxH),ih)',scale=trunc(iw/2)*2:trunc(ih/2)*2",
                                "-c:v", "h264_videotoolbox", "-b:v", "\(Int(videoK))k", "-maxrate", "\(Int(videoK * 1.2))k",
                                "-bufsize", "\(Int(videoK * 2))k", "-pix_fmt", "yuv420p",
                                "-c:a", "aac", "-b:a", "\(Int(audioK))k", "-movflags", "+faststart", out.path])
            let got = size(out)
            if got <= bytes { return out }
            videoK *= 0.92 * Double(bytes) / Double(got)
        }
        Runner.note = "Fichier créé, mais \(label(size(out))) au lieu de \(label(bytes)) : vidéo trop longue pour cette taille"
        return out
    }

    static func audio(_ u: URL, bytes: Int64) async throws -> URL {
        let d = await Media.duration(u)
        guard d > 0 else { throw ZError.msg("durée illisible") }
        let k = Int(max(32, min(320, Double(bytes) * 8 / 1000 / d * 0.95)))
        let out = Out.url(u, ext: "mp3", suffix: label(bytes))
        try await Media.ff(["-i", u.path, "-vn", "-c:a", "libmp3lame", "-b:a", "\(k)k", out.path])
        return out
    }

    /// Image : qualité JPEG ajustée par dichotomie, puis réduction de la taille si ça ne suffit pas.
    static func image(_ u: URL, bytes: Int64) async throws -> URL {
        var (img, _) = try Img.load(u)
        img = Img.flatten(img)
        func encode(_ i: CGImage, _ q: Double) -> Data? {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, i, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            return CGImageDestinationFinalize(dest) ? data as Data : nil
        }
        var current = img
        for _ in 0..<8 {
            var lo = 0.3, hi = 0.92
            var best: Data?
            if let d = encode(current, lo), d.count <= bytes {
                best = d
                for _ in 0..<7 {
                    let mid = (lo + hi) / 2
                    if let d = encode(current, mid), d.count <= bytes { best = d; lo = mid } else { hi = mid }
                }
            }
            if let best {
                let out = Out.url(u, ext: "jpg", suffix: label(bytes))
                try best.write(to: out)
                return out
            }
            // Trop lourd même à qualité basse : on réduit de 20 %.
            let w = Int(Double(current.width) * 0.8), h = Int(Double(current.height) * 0.8)
            guard w > 64, let ctx = Img.context(w, h, alpha: false) else { break }
            ctx.interpolationQuality = .high
            ctx.draw(current, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let smaller = ctx.makeImage() else { break }
            current = smaller
        }
        throw ZError.msg("impossible d'atteindre \(label(bytes))")
    }
}
