import AppKit
import AVFoundation
import AVKit
import CoreImage
import SwiftUI
import Vision

// MARK: - Fenêtres d'édition

@MainActor
enum Editors {
    static var windows: [NSWindow] = []

    static func present<V: View>(_ title: String, size: NSSize, _ view: (NSWindow) -> V) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 720, height: 460)
        w.contentView = NSHostingView(rootView: view(w))
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        windows.removeAll { !$0.isVisible }
        windows.append(w)
    }

    static func finished(_ out: URL, window: NSWindow?) {
        window?.close()
        HUD.shared.show("✓ " + out.lastPathComponent, reveal: [out], duration: 5)
        if Prefs.sound { NSSound(named: "Glass")?.play() }
    }

    static func failed(_ error: Error) {
        HUD.shared.show("✗ " + error.localizedDescription, duration: 9)
    }

    // Entrées de la roue
    static func photo(_ urls: [URL]) async throws -> [URL] {
        for u in urls.prefix(4) {
            let model = try PhotoModel(url: u)
            present("Retoucher · \(u.lastPathComponent)", size: NSSize(width: 1100, height: 720)) { PhotoEditorView(model: model, window: $0) }
        }
        return []
    }

    static func trim(_ urls: [URL]) async throws -> [URL] {
        for u in urls.prefix(4) {
            let model = TrimModel(url: u)
            present("Couper · \(u.lastPathComponent)", size: NSSize(width: 980, height: u.kind == .video ? 700 : 380)) { TrimEditorView(model: model, window: $0) }
        }
        return []
    }

    static func videoLook(_ urls: [URL]) async throws -> [URL] {
        for u in urls.prefix(4) {
            let asset = AVURLAsset(url: u)
            guard (try? await asset.load(.isPlayable)) == true else {
                throw ZError.msg("format vidéo non lisible par macOS : convertis-la d'abord en MP4 (⇧)")
            }
            let model = VideoLookModel(url: u, asset: asset)
            present("Retoucher · \(u.lastPathComponent)", size: NSSize(width: 1100, height: 720)) { VideoLookView(model: model, window: $0) }
        }
        return []
    }
}

// MARK: - Réglages de lumière et de couleur (Core Image, communs à la photo et à la vidéo)

struct Look: Equatable {
    var exposure = 0.0     // -2…2 IL
    var contrast = 0.0     // -1…1
    var saturation = 0.0   // -1…1
    var warmth = 0.0       // -1 (froid)…1 (chaud)
    var shadows = 0.0      // 0…1 : déboucher les ombres
    var highlights = 0.0   // 0…1 : récupérer les hautes lumières
    var sharpness = 0.0    // 0…1
    var vignette = 0.0     // 0…1

    var isIdentity: Bool { self == Look() }

    func apply(_ img: CIImage) -> CIImage {
        let extent = img.extent
        var o = img
        if exposure != 0 { o = o.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure]) }
        if contrast != 0 || saturation != 0 {
            o = o.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + contrast * 0.45,
                                                                kCIInputSaturationKey: 1 + saturation,
                                                                kCIInputBrightnessKey: 0])
        }
        if warmth != 0 {
            o = o.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0),
                                                                     "inputTargetNeutral": CIVector(x: 6500 + warmth * 2600, y: 0)])
        }
        if shadows != 0 || highlights != 0 {
            o = o.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": shadows,
                                                                        "inputHighlightAmount": 1 - highlights * 0.7])
        }
        if sharpness > 0 { o = o.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: sharpness * 1.2]) }
        if vignette > 0 {
            o = o.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputRadiusKey: hypot(extent.width, extent.height) * 0.42,
                kCIInputIntensityKey: vignette * 0.9, "inputFalloff": 0.6])
        }
        return o.cropped(to: extent)
    }
}

struct LookControls: View {
    @Binding var look: Look

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("Lumière") {
                row("Exposition", $look.exposure, -2...2)
                row("Contraste", $look.contrast, -1...1)
                row("Ombres", $look.shadows, 0...1)
                row("Hautes lumières", $look.highlights, 0...1)
            }
            group("Couleur") {
                row("Saturation", $look.saturation, -1...1)
                row("Chaleur", $look.warmth, -1...1)
            }
            group("Détails") {
                row("Netteté", $look.sharpness, 0...1)
                row("Vignette", $look.vignette, 0...1)
            }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(v.wrappedValue == 0 ? "0" : String(format: "%+.0f", v.wrappedValue / max(abs(r.lowerBound), r.upperBound) * 100))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: v, in: r)
                .onTapGesture(count: 2) { v.wrappedValue = 0 } // double-clic : remise à zéro
        }
    }
}

// MARK: - Éditeur photo

@MainActor
final class PhotoModel: ObservableObject {
    let url: URL
    private let full: CIImage
    private let small: CIImage
    private let meta: [CFString: Any]
    private let scale: CGFloat
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private var autoFilters: [CIFilter] = []
    private var maskFull: CIImage?
    private var pending: Task<Void, Never>?

    @Published var look = Look() { didSet { schedule() } }
    @Published var auto = false { didSet { schedule() } }
    @Published var removeBackground = false { didSet { Task { await toggleMask() } } }
    @Published var preview: NSImage?
    @Published var original: NSImage?
    @Published var busy = false
    @Published var maskStatus: String?

    init(url: URL) throws {
        self.url = url
        let (cg, meta) = try Img.load(url)
        self.meta = meta
        full = CIImage(cgImage: cg)
        scale = min(1, 1600 / max(full.extent.width, full.extent.height))
        small = full.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        autoFilters = small.autoAdjustmentFilters(options: [.redEye: false])
        original = render(small)
        preview = original
    }

    private func render(_ img: CIImage) -> NSImage? {
        guard let cg = ctx.createCGImage(img, from: img.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func pipeline(_ base: CIImage, mask: CIImage?) -> CIImage {
        var o = base
        if auto {
            for f in autoFilters {
                f.setValue(o, forKey: kCIInputImageKey)
                o = f.outputImage ?? o
            }
        }
        o = look.apply(o)
        if let mask {
            o = o.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        }
        return o.cropped(to: base.extent)
    }

    private var smallMask: CIImage? {
        maskFull?.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// Rendu regroupé : un seul calcul par image affichée, même si le curseur bouge vite.
    private func schedule() {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000)
            guard !Task.isCancelled else { return }
            preview = render(pipeline(small, mask: removeBackground ? smallMask : nil))
        }
    }

    private func toggleMask() async {
        if removeBackground && maskFull == nil {
            busy = true
            maskStatus = "Détection du sujet…"
            do { maskFull = try BackgroundRemover.mask(for: full, ctx: ctx) ; maskStatus = nil }
            catch { maskStatus = error.localizedDescription; removeBackground = false }
            busy = false
        }
        schedule()
    }

    func reset() { look = Look(); auto = false; removeBackground = false }

    func save() async throws -> URL {
        busy = true
        defer { busy = false }
        let out = pipeline(full, mask: removeBackground ? maskFull : nil)
        guard let cg = ctx.createCGImage(out, from: out.extent) else { throw ZError.msg("rendu impossible") }
        let ext = removeBackground ? "png" : Img.sameExt(url)
        let dest = Out.url(url, ext: ext, suffix: removeBackground ? "détourée" : "retouchée")
        try await Img.write(cg, meta: meta, to: dest, ext: ext, quality: 0.92)
        return dest
    }
}

struct PhotoEditorView: View {
    @ObservedObject var model: PhotoModel
    let window: NSWindow
    @State private var comparing = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Checkerboard().opacity(model.removeBackground ? 1 : 0)
                if let img = comparing ? model.original : model.preview {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(24)
                }
                if comparing {
                    VStack { Text("Avant").font(.callout.bold()).padding(6).background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white); Spacer() }.padding(.top, 36)
                }
                if model.busy { ProgressView().controlSize(.large) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.11))

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Toggle("Auto", isOn: $model.auto).toggleStyle(.button)
                    Toggle("Retirer le fond", isOn: $model.removeBackground).toggleStyle(.button)
                }
                if let s = model.maskStatus { Text(s).font(.caption).foregroundStyle(.secondary) }
                ScrollView { LookControls(look: $model.look).padding(.trailing, 6) }
                Spacer(minLength: 0)
                HStack {
                    Button("Réinitialiser") { model.reset() }
                    Spacer()
                    Text("Avant")
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(comparing ? 0.35 : 0.15)))
                        .onLongPressGesture(minimumDuration: 0, pressing: { comparing = $0 }, perform: {})
                        .help("Maintenir pour voir l'original")
                }
                Button {
                    Task {
                        do { Editors.finished(try await model.save(), window: window) } catch { Editors.failed(error) }
                    }
                } label: { Text("Enregistrer une copie").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(model.busy)
            }
            .padding(.horizontal, 20).padding(.top, 40).padding(.bottom, 20)
            .frame(width: 300)
            .background(Color(white: 0.15))
        }
        .environment(\.colorScheme, .dark)
        .tint(Color(nsColor: Prefs.accent.color))
    }
}

/// Damier gris derrière une image détourée, pour voir la transparence.
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 14
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(Color(white: 0.17)))
                }
            }
        }
    }
}

// MARK: - Retrait du fond (Vision, sur le Mac)

@MainActor
enum BackgroundRemover {
    nonisolated static func mask(for image: CIImage, ctx: CIContext) throws -> CIImage {
        guard let cg = ctx.createCGImage(image, from: image.extent) else { throw ZError.msg("image illisible") }
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([req])
        guard let obs = req.results?.first, !obs.allInstances.isEmpty else { throw ZError.msg("aucun sujet détecté") }
        let buf = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
        return CIImage(cvPixelBuffer: buf).transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
    }

    /// Entrée directe de la roue : PNG transparent à côté de l'original.
    static func run(_ u: URL) async throws -> URL {
        let (cg, _) = try Img.load(u)
        let img = CIImage(cgImage: cg)
        let ctx = CIContext()
        // Détourage hors du fil principal : la roue se ferme et le HUD tourne pendant le calcul.
        let m = try await Task.detached(priority: .userInitiated) { try mask(for: img, ctx: ctx) }.value
        let out = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: m])
        guard let res = ctx.createCGImage(out, from: img.extent) else { throw ZError.msg("détourage impossible") }
        let dest = Out.url(u, ext: "png", suffix: "détourée")
        try await Img.write(res, to: dest, ext: "png")
        return dest
    }
}

// MARK: - Couper avec la forme d'onde (audio et vidéo)

@MainActor
final class TrimModel: ObservableObject {
    let url: URL
    let isVideo: Bool
    let player: AVPlayer?
    @Published var peaks: [Float] = []
    @Published var duration = 0.0
    @Published var start = 0.0
    @Published var end = 0.0
    @Published var playhead = 0.0
    @Published var playing = false
    @Published var fade = false
    @Published var busy = false
    private var observer: Any?
    private var stopAt: Any?

    init(url: URL) {
        self.url = url
        isVideo = url.kind == .video
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        Task { await load() }
    }

    private func load() async {
        duration = await Media.duration(url)
        end = duration
        observer = player?.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.playhead = t.seconds }
        }
        // Forme d'onde : PCM mono 4 kHz décodé par ffmpeg, réduit à 1 400 colonnes.
        let raw = Out.temp("raw")
        defer { try? FileManager.default.removeItem(at: raw) }
        do {
            try await Media.ff(["-i", url.path, "-vn", "-ac", "1", "-ar", "4000", "-f", "s16le", raw.path])
            let data = try Data(contentsOf: raw)
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            let n = 1400
            guard !samples.isEmpty else { return }
            let per = max(1, samples.count / n)
            var out: [Float] = []
            out.reserveCapacity(n)
            var i = 0
            while i < samples.count {
                var m: Int32 = 0
                for s in samples[i..<min(i + per, samples.count)] { m = max(m, abs(Int32(s))) }
                out.append(Float(m) / 32768)
                i += per
            }
            let top = max(out.max() ?? 1, 0.01)
            peaks = out.map { min(1, $0 / top) }
        } catch {
            peaks = []
        }
    }

    func seek(_ t: Double) {
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = t
    }

    func togglePlay() {
        guard let p = player else { return }
        if playing { p.pause(); playing = false; return }
        if let s = stopAt { p.removeTimeObserver(s); stopAt = nil }
        seek(playhead < start || playhead >= end - 0.05 ? start : playhead)
        stopAt = p.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 600))], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.player?.pause(); self?.playing = false }
        }
        p.play()
        playing = true
    }

    /// Début et fin calés sur le premier et le dernier passage au-dessus du bruit de fond.
    func trimSilence() {
        guard !peaks.isEmpty, duration > 0 else { return }
        let threshold: Float = 0.06
        guard let first = peaks.firstIndex(where: { $0 > threshold }), let last = peaks.lastIndex(where: { $0 > threshold }) else { return }
        let step = duration / Double(peaks.count)
        start = max(0, Double(first) * step - 0.08)
        end = min(duration, Double(last + 1) * step + 0.08)
        seek(start)
    }

    func nudge(_ which: WritableKeyPath<TrimModel, Double>, by d: Double) {
        let v = self[keyPath: which] + d
        if which == \TrimModel.start { start = min(max(0, v), end - 0.1); seek(start) }
        else { end = max(min(duration, v), start + 0.1); seek(end) }
    }

    func export() async throws -> URL {
        player?.pause()
        playing = false
        busy = true
        defer { busy = false }
        let e = Media.sameExt(url)
        let out = Out.url(url, ext: e, suffix: "extrait")
        let len = end - start
        var codec: [String]
        if isVideo {
            codec = ["-map", "0:v:0", "-map", "0:a?"] + Media.encode(e)
        } else {
            codec = ["-vn"] + Media.audioCodec(e)
        }
        if fade {
            let f = min(0.5, len / 4)
            codec += ["-af", "afade=t=in:d=\(f),afade=t=out:st=\(max(0, len - f)):d=\(f)"]
        }
        try await Media.ff(["-ss", String(start), "-i", url.path, "-t", String(len)] + codec + [out.path])
        return out
    }
}

struct TrimEditorView: View {
    @ObservedObject var model: TrimModel
    let window: NSWindow

    var body: some View {
        VStack(spacing: 16) {
            if model.isVideo, let p = model.player {
                PlayerView(player: p)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxHeight: .infinity)
            }
            Waveform(model: model)
                .frame(height: model.isVideo ? 110 : 170)
            HStack(spacing: 18) {
                timeBox("Début", model.start, \.start)
                Spacer()
                Text("Sélection : \(Ask.clock(model.end - model.start)) / \(Ask.clock(model.duration))")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                timeBox("Fin", model.end, \.end)
            }
            HStack {
                Button { model.togglePlay() } label: {
                    Label(model.playing ? "Pause" : "Écouter la sélection", systemImage: model.playing ? "pause.fill" : "play.fill")
                }
                .keyboardShortcut(.space, modifiers: [])
                Button("Retirer les silences aux extrémités") { model.trimSilence() }
                Toggle("Fondu entrée et sortie", isOn: $model.fade)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Couper et enregistrer") {
                    Task {
                        do { Editors.finished(try await model.export(), window: window) } catch { Editors.failed(error) }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy || model.duration == 0)
            }
        }
        .padding(.horizontal, 22).padding(.top, 38).padding(.bottom, 20)
        .background(Color(white: 0.11))
        .environment(\.colorScheme, .dark)
        .tint(Color(nsColor: Prefs.accent.color))
    }

    private func timeBox(_ title: String, _ value: Double, _ key: WritableKeyPath<TrimModel, Double>) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Button { model.nudge(key, by: -0.1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
            Text(precise(value)).font(.body.monospacedDigit()).frame(minWidth: 70)
            Button { model.nudge(key, by: 0.1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
        }
    }

    private func precise(_ t: Double) -> String {
        let cs = Int((t * 100).rounded())
        return String(format: "%d:%02d.%02d", cs / 6000, cs / 100 % 60, cs % 100)
    }
}

/// Forme d'onde : poignées de début et de fin à faire glisser, clic pour placer la tête de lecture.
struct Waveform: View {
    @ObservedObject var model: TrimModel
    @State private var dragging: Int? = nil // 0 : début, 1 : fin, 2 : tête de lecture

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let d = max(model.duration, 0.001)
            let x0 = CGFloat(model.start / d) * w, x1 = CGFloat(model.end / d) * w
            let accent = Color(nsColor: Prefs.accent.color)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05))
                Canvas { ctx, size in
                    let n = model.peaks.count
                    guard n > 0 else { return }
                    let bar = size.width / CGFloat(n)
                    for (i, p) in model.peaks.enumerated() {
                        let x = CGFloat(i) * bar
                        let bh = max(1.5, CGFloat(p) * (size.height - 16))
                        let inside = x >= x0 && x <= x1
                        ctx.fill(Path(CGRect(x: x, y: (size.height - bh) / 2, width: max(bar * 0.7, 1), height: bh)),
                                 with: .color(inside ? accent : Color.white.opacity(0.25)))
                    }
                }
                Rectangle().fill(accent.opacity(0.12)).frame(width: max(0, x1 - x0)).offset(x: x0)
                handle(accent).offset(x: x0 - 5)
                handle(accent).offset(x: x1 - 5)
                Rectangle().fill(Color.white).frame(width: 1.5).offset(x: CGFloat(model.playhead / d) * w)
                if model.peaks.isEmpty {
                    Text(model.duration == 0 ? "Analyse…" : "Pas de piste audio").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let t = min(max(0, Double(g.location.x / w) * d), d)
                    if dragging == nil {
                        let s = abs(g.startLocation.x - x0), e = abs(g.startLocation.x - x1)
                        dragging = min(s, e) < 14 ? (s < e ? 0 : 1) : 2
                    }
                    switch dragging {
                    case 0: model.start = min(t, model.end - 0.1); model.seek(model.start)
                    case 1: model.end = max(t, model.start + 0.1); model.seek(model.end)
                    default: model.seek(t)
                    }
                }
                .onEnded { _ in dragging = nil })
            .frame(width: w, height: h)
        }
    }

    private func handle(_ c: Color) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 10)
            .overlay(Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 22))
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { v.player = player }
}

// MARK: - Retoucher une vidéo (mêmes réglages que la photo, aperçu en lecture)

@MainActor
final class VideoLookModel: ObservableObject {
    let url: URL
    let asset: AVURLAsset
    let player: AVPlayer
    @Published var look = Look() { didSet { refresh() } }
    @Published var busy = false
    @Published var progress = 0.0
    /// Lu par le filtre vidéo à chaque image : l'aperçu suit les curseurs en direct.
    private let box = LookBox()

    init(url: URL, asset: AVURLAsset) {
        self.url = url
        self.asset = asset
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        Task { await attach() }
    }

    private func composition() async throws -> AVVideoComposition {
        let box = self.box
        return try await AVVideoComposition.videoComposition(with: asset) { req in
            let src = req.sourceImage.clampedToExtent()
            req.finish(with: box.look.apply(src).cropped(to: req.sourceImage.extent), context: nil)
        }
    }

    private func attach() async {
        if let vc = try? await composition() { player.currentItem?.videoComposition = vc }
        player.play()
    }

    private func refresh() {
        box.look = look
        // À l'arrêt, une nouvelle composition force le rafraîchissement de l'image affichée.
        if player.rate == 0, let item = player.currentItem {
            Task { if let vc = try? await composition() { item.videoComposition = vc } }
        }
    }

    func export() async throws -> URL {
        player.pause()
        busy = true
        defer { busy = false }
        let out = Out.url(url, ext: "mp4", suffix: "retouchée")
        guard let exp = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ZError.msg("export impossible")
        }
        exp.videoComposition = try await composition()
        exp.outputURL = out
        exp.outputFileType = .mp4
        exp.shouldOptimizeForNetworkUse = true
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self, weak exp] _ in
            MainActor.assumeIsolated { self?.progress = Double(exp?.progress ?? 0) }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in exp.exportAsynchronously { c.resume() } }
        timer.invalidate()
        guard exp.status == .completed else { throw ZError.msg("export : \(exp.error?.localizedDescription ?? "échec")") }
        return out
    }
}

final class LookBox: @unchecked Sendable {
    var look = Look()
}

struct VideoLookView: View {
    @ObservedObject var model: VideoLookModel
    let window: NSWindow

    var body: some View {
        HStack(spacing: 0) {
            VStack {
                PlayerView(player: model.player).clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    Button { model.player.rate == 0 ? model.player.play() : model.player.pause() } label: { Image(systemName: "playpause.fill") }
                        .keyboardShortcut(.space, modifiers: [])
                    Text("Espace : lecture / pause").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(24).padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.11))

            VStack(alignment: .leading, spacing: 16) {
                ScrollView { LookControls(look: $model.look).padding(.trailing, 6) }
                Spacer(minLength: 0)
                Button("Réinitialiser") { model.look = Look() }
                if model.busy { ProgressView(value: model.progress).progressViewStyle(.linear) }
                Button {
                    Task {
                        do { Editors.finished(try await model.export(), window: window) } catch { Editors.failed(error) }
                    }
                } label: { Text("Enregistrer une copie").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.look.isIdentity)
            }
            .padding(.horizontal, 20).padding(.top, 40).padding(.bottom, 20)
            .frame(width: 300)
            .background(Color(white: 0.15))
        }
        .environment(\.colorScheme, .dark)
        .tint(Color(nsColor: Prefs.accent.color))
    }
}
