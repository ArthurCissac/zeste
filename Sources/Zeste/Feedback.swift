import AppKit

/// Petits retours sensoriels : un clic sec au survol d'une part, une note grave à l'ouverture,
/// et le retour haptique du trackpad. Les sons sont synthétisés ici (aucun fichier audio).
@MainActor
enum Feedback {
    private static let tickSounds = (0..<4).compactMap { _ in NSSound(data: click(freqs: [3100, 5300], decay: 0.0016, length: 0.018, gain: 0.55)) }
    private static let openSound = NSSound(data: click(freqs: [880, 1320], decay: 0.006, length: 0.05, gain: 0.35))
    private static let selectSound = NSSound(data: click(freqs: [1500, 2250], decay: 0.004, length: 0.04, gain: 0.5))
    private static var next = 0

    static func tick() {
        guard Prefs.clicks, !tickSounds.isEmpty else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        // Plusieurs voix en rotation : un survol rapide ne coupe pas le clic précédent.
        let s = tickSounds[next % tickSounds.count]
        next += 1
        s.stop()
        s.play()
    }

    static func open() {
        guard Prefs.clicks else { return }
        openSound?.stop()
        openSound?.play()
    }

    static func select() {
        guard Prefs.clicks else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        selectSound?.stop()
        selectSound?.play()
    }

    /// WAV 16 bits mono : quelques sinusoïdes à décroissance exponentielle très rapide.
    private static func click(freqs: [Double], decay: Double, length: Double, gain: Double) -> Data {
        let rate = 44_100
        let count = Int(Double(rate) * length)
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            let env = exp(-t / decay) * min(1, t * 20_000) // attaque de 0,05 ms, sans claquement
            let v = freqs.reduce(0.0) { $0 + sin(2 * .pi * $1 * t) } / Double(freqs.count)
            var s = Int16(max(-1, min(1, v * env * gain)) * Double(Int16.max)).littleEndian
            pcm.append(Data(bytes: &s, count: 2))
        }
        var wav = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 2)) }
        wav.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count))
        wav.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        wav.append("data".data(using: .ascii)!); u32(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}
