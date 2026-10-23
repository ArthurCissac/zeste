import Foundation

/// Lancement des outils en ligne de commande (ffmpeg, cwebp, ditto, tar, osascript…), sans shell :
/// les chemins sont passés tels quels en arguments, jamais interprétés.
enum Shell {
    /// Les outils embarqués dans l'app (Contents/Resources/bin) passent avant ceux de Homebrew.
    static func find(_ name: String) -> String? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/\(name)").path,
           FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin"] {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func ffmpeg() throws -> String {
        guard let p = find("ffmpeg") else { throw ZError.msg("ffmpeg introuvable : réinstalle Zeste") }
        return p
    }

    static func ffprobe() throws -> String {
        guard let p = find("ffprobe") else { throw ZError.msg("ffprobe introuvable : réinstalle Zeste") }
        return p
    }

    /// Exécute `exe` et renvoie sa sortie standard. `stdoutFile` redirige la sortie vers un fichier.
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil, stdoutFile: URL? = nil, timeout: Double = 3600) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }

            let outPipe = Pipe(), errPipe = Pipe()
            var outHandle: FileHandle?
            if let f = stdoutFile {
                FileManager.default.createFile(atPath: f.path, contents: nil)
                outHandle = try? FileHandle(forWritingTo: f)
                p.standardOutput = outHandle
            } else {
                p.standardOutput = outPipe
            }
            p.standardError = errPipe

            // Lecture au fil de l'eau : un tube plein bloquerait le processus (ffmpeg est bavard).
            let lock = NSLock()
            var outData = Data(), errData = Data()
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData; lock.lock(); outData.append(d); lock.unlock()
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData; lock.lock(); errData.append(d); lock.unlock()
            }

            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

            p.terminationHandler = { proc in
                timer.cancel()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let restOut = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let restErr = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                try? outHandle?.close()
                lock.lock(); outData.append(restOut); errData.append(restErr); lock.unlock()
                let out = String(decoding: outData, as: UTF8.self)
                let err = String(decoding: errData, as: UTF8.self)
                if proc.terminationStatus == 0 {
                    cont.resume(returning: out)
                } else {
                    let tail = err.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }.suffix(2).joined(separator: " — ")
                    let name = URL(fileURLWithPath: exe).lastPathComponent
                    cont.resume(throwing: ZError.msg(tail.isEmpty ? "\(name) a échoué (code \(proc.terminationStatus))" : tail))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
