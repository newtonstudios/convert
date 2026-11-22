import Foundation

enum Converter {
    /// Converts one file and returns what was written (files, or a folder for multi-page PDFs).
    /// Stopped (`runner.cancel()`) or failed conversions throw and leave nothing half-written behind.
    static func convert(
        _ input: URL, to t: Target, settings s: ConvSettings, runner: Runner,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL] {
        // A file whose contents don't match its name gets told so, instead of a vague decode error.
        if let kind = MediaKind.of(input) { try Sniff.verify(input, as: kind) }
        switch t.group {
        case .audio, .video:
            guard let ff = Tools.ffmpeg else {
                throw ConvertError("ffmpeg isn't installed. Install it with: brew install ffmpeg")
            }
            let p = await Task.detached { FF.probe(input) }.value
            if p.ok, t.group == .audio, !p.hasAudio { throw ConvertError("This file has no audio track") }
            if p.ok, t.group == .video, !p.hasVideo { throw ConvertError("This file has no video track") }
            let out = try uniqueOutput(for: input, ext: t.ext)
            try await withSoftwareFallback(t, s, runner: runner) { s in
                let codec = t.group == .audio ? FF.audioArgs(t, s, p) : FF.videoArgs(t, s, p)
                let args = FF.common + ["-i", input.path] + codec + [out.path]
                do {
                    try await runner.run(ff, args, duration: p.duration, progress: progress)
                } catch {
                    try? FileManager.default.removeItem(at: out)
                    throw error
                }
            }
            return [out]

        case .image:
            return [try await Task.detached { try ImageConv.convert(input, t, s, runner: runner) }.value]

        case .document:
            if t.id == "pdf-doc" {
                let out = try uniqueOutput(for: input, ext: "pdf")
                try await DocConv.toPDF(input, out, a4: s.paperA4, runner: runner)
                return [out]
            }
            if t.id == "md" {
                return [try await Task.detached { try DocConv.markdown(input, runner: runner) }.value]
            }
            return [try await Task.detached { try DocConv.textutil(input, t, runner: runner) }.value]

        case .pdfPages:
            return try await Task.detached {
                try PDFConv.convert(input, t, s, runner: runner, progress: progress)
            }.value

        case .font:
            return try await FontConv.convert(input, t, runner: runner)
        }
    }

    /// Formats with a hardware encoder use it by default, but not every Mac has every one (ProRes,
    /// HEVC on older Intel Macs, virtual machines), and ffmpeg then fails. Rather than fail the
    /// conversion, it's tried once more with the software encoder: slower, but it works anywhere.
    static func withSoftwareFallback(
        _ t: Target, _ s: ConvSettings, runner: Runner,
        _ encode: (ConvSettings) async throws -> Void
    ) async throws {
        do {
            try await encode(s)
        } catch {
            guard t.hasHardwareOption, s.hardware, !runner.isCancelled else { throw error }
            var software = s
            software.hardware = false
            try await encode(software)
        }
    }
}
