import Foundation
import Testing

@testable import Convert

/// The ffmpeg arguments for video targets: the filter chain that decides the output size.
final class VideoArgsTests {
    private let source = Probe(duration: 1, hasVideo: true, ok: true)
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func args(_ id: String, hardware: Bool = false, height: Int = 0, fps: Int = 0) throws -> [String] {
        let target = try #require(Targets.byID(id), "no target \(id)")
        var s = ConvSettings()
        s.hardware = hardware
        s.videoHeight = height
        s.fps = fps
        return FF.videoArgs(target, s, source)
    }

    /// The `-vf` filter chain, or nil without one.
    private func vf(_ a: [String]) -> String? {
        guard let i = a.firstIndex(of: "-vf"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    // MARK: Even sizes

    @Test func fourTwoZeroTargetsAlwaysGetAnEvenSize() throws {
        for id in ["mp4-h264", "mkv", "mp4-hevc", "mp4-av1"] {
            for hardware in [false, true] {
                let a = try args(id, hardware: hardware)
                #expect(vf(a) == FF.evenSize, "\(id) hardware: \(hardware)")
                #expect(a.filter { $0 == "-vf" }.count == 1, "\(id)")
            }
        }
    }

    @Test func evenSizeComesAfterScaling() throws {
        // scale=-2 makes the width even, but a height capped at the source's own can still be odd.
        let a = try args("mp4-h264", height: 720, fps: 30)
        #expect(vf(a) == "fps=30,scale=-2:min(ih\\,720),\(FF.evenSize)")
    }

    @Test func targetsThatTakeOddSizesAreLeftAlone() throws {
        for id in ["webm", "mov-prores"] {
            #expect(vf(try args(id)) == nil, "\(id)")
            #expect(vf(try args(id, height: 720)) == "scale=-2:min(ih\\,720)", "\(id)")
        }
        let gif = try args("gif")
        #expect(!gif.joined(separator: " ").contains("crop="))
    }

    // MARK: End to end

    /// What ffprobe says the first video stream's size is.
    private func size(_ url: URL) throws -> String {
        let ffprobe = try #require(Tools.ffprobe)
        let out = try runSync(
            ffprobe,
            [
                "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0",
                url.path,
            ])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test(.enabled(if: Tools.ffmpeg != nil && Tools.ffprobe != nil, "needs ffmpeg"))
    func oddSizedVideoConvertsToH264() async throws {
        let ffmpeg = try #require(Tools.ffmpeg)
        let input = dir.appendingPathComponent("odd.mov")
        try runSync(
            ffmpeg,
            [
                "-hide_banner", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i",
                "testsrc=duration=0.5:size=321x241:rate=10", "-c:v", "mjpeg", input.path,
            ])
        #expect(try size(input) == "321,241")

        var s = ConvSettings()
        s.hardware = false  // libx264 is the encoder that refuses odd sizes
        let target = try #require(Targets.byID("mp4-h264"))
        let outputs = try await Converter.convert(input, to: target, settings: s, runner: Runner()) { _ in }
        let out = try #require(outputs.first)
        #expect(try size(out) == "320,240")
    }
}
