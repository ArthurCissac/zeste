import Foundation

/// Vidéo et audio, avec ffmpeg (hors ligne).
@MainActor
enum Media {
    static let audioExts: Set<String> = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma", "aac"]

    static func ff(_ args: [String]) async throws {
        try await Shell.run(try Shell.ffmpeg(), ["-hide_banner", "-nostdin", "-y"] + args)
    }

    // MARK: Infos

    static func duration(_ u: URL) async -> Double {
        guard let probe = try? Shell.ffprobe(),
              let s = try? await Shell.run(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", u.path])
        else { return 0 }
        return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    static func hasAudio(_ u: URL) async -> Bool {
        guard let probe = try? Shell.ffprobe(),
              let s = try? await Shell.run(probe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", u.path])
        else { return false }
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func dimensions(_ u: URL) async -> (Int, Int) {
        guard let probe = try? Shell.ffprobe(),
              let s = try? await Shell.run(probe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x", u.path])
        else { return (1280, 720) }
        let p = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "x").compactMap { Int($0) }
        return p.count == 2 ? (p[0] / 2 * 2, p[1] / 2 * 2) : (1280, 720)
    }

    // MARK: Paramètres d'encodage par conteneur

    static let even = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    static let gifFilter = "fps=12,scale='min(720,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4"

    /// Codecs vidéo + audio selon l'extension de sortie. `vf` : filtre vidéo à appliquer avant.
    static func encode(_ ext: String, vf: String? = nil, crf: String = "21", audioBitrate: String = "160k") -> [String] {
        func filter(_ last: String?) -> [String] {
            let parts = [vf, last].compactMap { $0 }
            return parts.isEmpty ? [] : ["-vf", parts.joined(separator: ",")]
        }
        switch ext {
        case "mp4", "mov", "mkv", "m4v", "3gp", "mpg", "mpeg":
            let x264 = filter(even) + ["-c:v", "libx264", "-preset", "veryfast", "-crf", crf, "-pix_fmt", "yuv420p",
                                       "-c:a", "aac", "-b:a", audioBitrate]
            return x264 + (ext == "mp4" || ext == "m4v" ? ["-movflags", "+faststart"] : [])
        case "webm":
            return filter(nil) + ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good",
                                  "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k"]
        case "avi":
            return filter(even) + ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]
        case "wmv":
            return filter(even) + ["-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2", "-b:a", "192k"]
        case "gif":
            let g = [vf, gifFilter].compactMap { $0 }.joined(separator: ",")
            return ["-vf", g, "-loop", "0"]
        case "webp":
            return filter(nil) + ["-c:v", "libwebp_anim", "-lossless", "0", "-q:v", "75", "-loop", "0"]
        default:
            return ["-vn"] + audioCodec(ext)
        }
    }

    /// Codecs seuls, sans -vf (pour les commandes qui utilisent déjà -filter_complex).
    static func codecOnly(_ ext: String) -> [String] {
        var a = encode(ext)
        if let i = a.firstIndex(of: "-vf") { a.removeSubrange(i...(i + 1)) }
        return a
    }

    static func audioCodec(_ ext: String, bitrate: String? = nil) -> [String] {
        switch ext {
        case "mp3": return ["-c:a", "libmp3lame"] + (bitrate.map { ["-b:a", $0] } ?? ["-q:a", "2"])
        case "m4a", "aac": return ["-c:a", "aac", "-b:a", bitrate ?? "192k"]
        case "wav": return ["-c:a", "pcm_s16le"]
        case "flac": return ["-c:a", "flac"]
        case "ogg": return ["-c:a", "libvorbis", "-q:a", "5"]
        case "opus": return ["-c:a", "libopus", "-b:a", bitrate ?? "128k"]
        case "aiff": return ["-c:a", "pcm_s16be"]
        case "wma": return ["-c:a", "wmav2", "-b:a", bitrate ?? "192k"]
        default: return ["-c:a", "aac", "-b:a", "192k"]
        }
    }

    /// Extension de sortie « identique » quand l'outil ne change pas le format.
    static func sameExt(_ u: URL) -> String {
        let e = u.normExt
        if u.kind == .audio { return audioExts.contains(e) ? e : "m4a" }
        if e == "gif" { return "gif" }
        return ["mp4", "mov", "mkv", "webm", "avi", "wmv"].contains(e) ? e : "mp4"
    }

    // MARK: Conversions

    static func convert(_ u: URL, to ext: String) async throws -> URL {
        let out = Out.url(u, ext: ext)
        let input = ["-i", u.path]
        if ext == "mkv" {
            // MKV accepte presque tous les codecs : copie directe, sans perte, en quelques secondes.
            do { try await ff(input + ["-map", "0", "-c", "copy", out.path]); return out }
            catch { try? FileManager.default.removeItem(at: out) }
        }
        if audioExts.contains(ext) {
            try await ff(input + ["-vn", "-map_metadata", "0"] + audioCodec(ext) + [out.path])
        } else {
            // GIF et WebP animé n'ont pas de piste audio.
            let audio = (ext == "gif" || ext == "webp") ? ["-an"] : ["-map", "0:a?"]
            try await ff(input + ["-map", "0:v:0"] + audio + encode(ext) + [out.path])
        }
        return out
    }

    // MARK: Outils vidéo

    static func compressVideo(_ u: URL) async throws -> URL {
        let out = Out.url(u, ext: "mp4", suffix: "compressé")
        try await ff(["-i", u.path, "-map", "0:v:0", "-map", "0:a?"]
                     + encode("mp4", vf: "scale='min(1920,iw)':-2", crf: "28", audioBitrate: "128k") + [out.path])
        return out
    }

    static func to720(_ u: URL) async throws -> URL {
        let e = sameExt(u)
        let out = Out.url(u, ext: e, suffix: "720p")
        try await ff(["-i", u.path, "-map", "0:v:0", "-map", "0:a?"] + encode(e, vf: "scale=-2:'min(720,ih)'") + [out.path])
        return out
    }

    static func compressGIF(_ u: URL) async throws -> URL {
        let out = Out.url(u, ext: "gif", suffix: "compressé")
        try await ff(["-i", u.path, "-vf",
                      "fps=10,scale='min(480,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3",
                      "-loop", "0", out.path])
        return out
    }

    static func trim(_ u: URL) async throws -> URL {
        let d = await duration(u)
        guard let (start, end) = Ask.range(title: "Couper « \(u.lastPathComponent) »", duration: d) else { throw ZError.cancelled }
        let e = sameExt(u)
        let out = Out.url(u, ext: e, suffix: "extrait")
        let codec = u.kind == .audio ? ["-vn"] + audioCodec(e)
            : ["-map", "0:v:0"] + (e == "gif" ? ["-an"] : ["-map", "0:a?"]) + encode(e)
        try await ff(["-ss", String(start), "-i", u.path, "-t", String(end - start)] + codec + [out.path])
        return out
    }

    static func split(_ u: URL) async throws -> [URL] {
        let d = await duration(u)
        guard let text = Ask.text(title: "Découper « \(u.lastPathComponent) »",
                                  info: "Durée totale : \(Ask.clock(d)). Durée de chaque morceau (mm:ss ou secondes) :",
                                  initial: d > 120 ? "1:00" : "0:10"),
              let seg = Ask.seconds(text), seg > 0 else { throw ZError.cancelled }
        let e = u.normExt
        let dir = try Out.folder(u, suffix: "(morceaux)")
        let pattern = dir.appendingPathComponent("\(u.baseName) %03d.\(e)").path
        // Vidéo : réencodage avec une image clé forcée à chaque coupe, sinon les morceaux tombent
        // sur les images clés d'origine (parfois une seule par fichier). L'audio se copie tel quel.
        let codec = u.kind == .audio ? ["-map", "0:a", "-c", "copy"]
            : ["-map", "0:v:0", "-map", "0:a?"] + encode(e) + ["-force_key_frames", "expr:gte(t,n_forced*\(seg))"]
        try await ff(["-i", u.path] + codec + ["-f", "segment", "-segment_time", String(seg),
                      "-reset_timestamps", "1", pattern])
        return [dir]
    }

    static func mute(_ u: URL) async throws -> URL {
        let out = Out.url(u, ext: u.normExt, suffix: "sans son")
        try await ff(["-i", u.path, "-map", "0:v", "-c:v", "copy", "-an", out.path])
        return out
    }

    static func rotateVideo(_ u: URL) async throws -> URL {
        let e = sameExt(u)
        let out = Out.url(u, ext: e, suffix: "pivotée")
        try await ff(["-i", u.path, "-map", "0:v:0", "-map", "0:a?"] + encode(e, vf: "transpose=1") + [out.path])
        return out
    }

    static func speed2x(_ u: URL) async throws -> URL {
        let e = sameExt(u)
        let out = Out.url(u, ext: e, suffix: "x2")
        if await hasAudio(u) {
            // Avec -filter_complex, pas de -vf : la mise à taille paire passe dans le graphe.
            let vf = e == "gif" ? "setpts=0.5*PTS" : "setpts=0.5*PTS,\(even)"
            try await ff(["-i", u.path, "-filter_complex", "[0:v]\(vf)[v];[0:a]atempo=2.0[a]",
                          "-map", "[v]", "-map", "[a]"] + codecOnly(e) + [out.path])
        } else {
            try await ff(["-i", u.path, "-map", "0:v:0"] + encode(e, vf: "setpts=0.5*PTS") + [out.path])
        }
        return out
    }

    static func frame(_ u: URL) async throws -> URL {
        let at = await duration(u) / 2
        let out = Out.url(u, ext: "jpg", suffix: "image")
        try await ff(["-ss", String(at), "-i", u.path, "-frames:v", "1", "-q:v", "2", out.path])
        return out
    }

    /// Vidéos mises bout à bout, recalées sur la taille de la première.
    static func mergeVideos(_ urls: [URL]) async throws -> [URL] {
        let files = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let (w, h) = await dimensions(files[0])
        var allAudio = true
        for f in files where !(await hasAudio(f)) { allAudio = false }
        var inputs: [String] = []
        var graph = ""
        var chain = ""
        for (i, f) in files.enumerated() {
            inputs += ["-i", f.path]
            graph += "[\(i):v:0]scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v\(i)];"
            if allAudio { graph += "[\(i):a:0]aresample=48000[a\(i)];" }
            chain += allAudio ? "[v\(i)][a\(i)]" : "[v\(i)]"
        }
        graph += chain + "concat=n=\(files.count):v=1:a=\(allAudio ? 1 : 0)" + (allAudio ? "[v][a]" : "[v]")
        let out = Out.unique(Out.dir(for: files[0]).appendingPathComponent("Fusion.mp4"))
        var maps = ["-map", "[v]"]
        if allAudio { maps += ["-map", "[a]"] }
        try await ff(inputs + ["-filter_complex", graph] + maps
                     + ["-c:v", "libx264", "-preset", "veryfast", "-crf", "21", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", out.path])
        return [out]
    }

    // MARK: Outils audio

    static func compressAudio(_ u: URL) async throws -> URL {
        let out = Out.url(u, ext: "mp3", suffix: "compressé")
        try await ff(["-i", u.path, "-vn"] + audioCodec("mp3", bitrate: "128k") + [out.path])
        return out
    }

    static func normalize(_ u: URL) async throws -> URL {
        let e = sameExt(u)
        let out = Out.url(u, ext: e, suffix: "normalisé")
        try await ff(["-i", u.path, "-vn", "-af", "loudnorm=I=-16:TP=-1.5:LRA=11"] + audioCodec(e) + [out.path])
        return out
    }

    static func mono(_ u: URL) async throws -> URL {
        let e = sameExt(u)
        let out = Out.url(u, ext: e, suffix: "mono")
        try await ff(["-i", u.path, "-vn", "-ac", "1"] + audioCodec(e) + [out.path])
        return out
    }

    static func mergeAudio(_ urls: [URL]) async throws -> [URL] {
        let files = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let e = sameExt(files[0])
        var inputs: [String] = []
        var chain = ""
        for (i, f) in files.enumerated() {
            inputs += ["-i", f.path]
            chain += "[\(i):a:0]"
        }
        let out = Out.unique(Out.dir(for: files[0]).appendingPathComponent("Fusion.\(e)"))
        try await ff(inputs + ["-filter_complex", chain + "concat=n=\(files.count):v=0:a=1[a]", "-map", "[a]"] + audioCodec(e) + [out.path])
        return [out]
    }
}
