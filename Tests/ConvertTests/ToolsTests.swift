import Foundation
import Testing

@testable import Convert

/// Running the external tools (ffmpeg, ffprobe, cwebp, textutil): finding them, reading their
/// output, and coping when one of them can't do what was asked.
final class ToolsTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A stand-in for a chatty tool: writes 1 MB to stderr (far more than a pipe holds),
    /// then one last line, and exits with `status`.
    private func chatty(lastLine: String, status: Int) -> [String] {
        [
            "-c",
            """
            head -c 1048576 /dev/zero | tr '\\0' 'x' >&2
            echo >&2
            echo "to stdout"
            echo "\(lastLine)" >&2
            exit \(status)
            """,
        ]
    }

    // MARK: Finding tools

    @Test func aToolInstalledLaterIsFoundWithoutARestart() throws {
        #expect(Tools.find("ffmpeg", in: [dir.path]) == nil)
        // "brew install ffmpeg" happens while the app is open.
        let tool = dir.appendingPathComponent("ffmpeg")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        #expect(Tools.find("ffmpeg", in: [dir.path]) == tool.path)
        // And uninstalled again.
        try FileManager.default.removeItem(at: tool)
        #expect(Tools.find("ffmpeg", in: [dir.path]) == nil)
    }

    @Test func firstDirectoryWinsAndNonExecutablesDontCount() throws {
        let other = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        for folder in [dir, other] {
            let tool = folder.appendingPathComponent("cwebp")
            try Data("#!/bin/sh\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        try Data("not a program".utf8).write(to: dir.appendingPathComponent("ffprobe"))
        #expect(Tools.find("cwebp", in: [other.path, dir.path]) == other.appendingPathComponent("cwebp").path)
        #expect(Tools.find("ffprobe", in: [dir.path]) == nil)
    }

    @Test func webPIsOfferedExactlyWhenCwebpIsInstalled() {
        #expect(Targets.all.contains { $0.id == "webp" } == (Tools.cwebp != nil))
        #expect(Targets.all.count == Set(Targets.all.map(\.id)).count)
    }

    // MARK: Reading output

    @Test(.timeLimit(.minutes(1)))
    func aToolThatFloodsStderrStillFinishes() throws {
        let stdout = try runSync("/bin/sh", chatty(lastLine: "done", status: 0))
        #expect(stdout == "to stdout\n")
    }

    @Test(.timeLimit(.minutes(1)))
    func aFloodedFailureStillReportsItsLastLine() throws {
        let error = #expect(throws: ConvertError.self) {
            try runSync("/bin/sh", chatty(lastLine: "the actual reason", status: 2))
        }
        #expect(error?.message == "the actual reason")
    }

    @Test(.timeLimit(.minutes(1)))
    func theProgressRunnerCopesWithAFloodToo() async throws {
        try await Runner().run("/bin/sh", chatty(lastLine: "done", status: 0), duration: 0) { _ in }
        let error = await #expect(throws: ConvertError.self) {
            try await Runner().run("/bin/sh", self.chatty(lastLine: "the actual reason", status: 2), duration: 0) {
                _ in
            }
        }
        #expect(error?.message == "the actual reason")
    }

    @Test func aToolWithNoErrorOutputGetsAGenericMessage() {
        let error = #expect(throws: ConvertError.self) { try runSync("/usr/bin/false", []) }
        #expect(error?.message == "false failed")
    }

    /// runSync blocks the thread it runs on, and tests run in parallel on a pool with one thread
    /// per core (CI's Mac has 3). More calls at once than there are cores must still finish.
    @Test(.timeLimit(.minutes(1)))
    func moreCallsAtOnceThanCoresStillFinish() async throws {
        let calls = ProcessInfo.processInfo.activeProcessorCount * 3
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<calls {
                group.addTask { try runSync("/bin/sh", ["-c", "echo out; echo err >&2"]) }
            }
            for try await out in group { #expect(out == "out\n") }
        }
    }

    // MARK: ffmpeg progress

    private let report = """
        frame=10
        out_time_us=2500000
        progress=continue
        frame=20
        out_time_us=5000000
        out_time_us=N/A
        progress=continue
        out_time_us=12000000
        progress=end

        """

    @Test func progressFromWholeLines() {
        var parser = ProgressParser(duration: 10)
        #expect(parser.feed(Data(report.utf8)) == [0.25, 0.5, 1])
    }

    @Test func progressLinesSplitAcrossReadsAreNotLost() {
        let bytes = Array(report.utf8)
        // Every possible chunk size, including one byte at a time: the result never changes.
        for size in 1...bytes.count {
            var parser = ProgressParser(duration: 10)
            var fractions: [Double] = []
            for start in stride(from: 0, to: bytes.count, by: size) {
                fractions += parser.feed(Data(bytes[start..<min(start + size, bytes.count)]))
            }
            #expect(fractions == [0.25, 0.5, 1], "chunks of \(size)")
        }
    }

    @Test func progressNeedsAKnownDurationAndACompleteLine() {
        var unknown = ProgressParser(duration: 0)
        #expect(unknown.feed(Data(report.utf8)).isEmpty)
        var parser = ProgressParser(duration: 10)
        #expect(parser.feed(Data("out_time_us=5000000".utf8)).isEmpty)  // no newline yet
        #expect(parser.feed(Data("\n".utf8)) == [0.5])
    }

    // MARK: Hardware encoder fallback

    private func encode(
        _ id: String, hardware: Bool, runner: Runner = Runner(), failing: @escaping (ConvSettings) -> Bool
    ) async throws -> [Bool] {
        let target = try #require(Targets.byID(id))
        var settings = ConvSettings()
        settings.hardware = hardware
        let attempts = Attempts()
        do {
            try await Converter.withSoftwareFallback(target, settings, runner: runner) { s in
                attempts.add(s.hardware)
                if failing(s) { throw ConvertError("Error while opening encoder") }
            }
        } catch {
            throw FallbackFailure(attempts: attempts.all, error: error)
        }
        return attempts.all
    }

    private struct FallbackFailure: Error {
        let attempts: [Bool]
        let error: Error
    }

    @Test func hardwareEncoderMissingFallsBackToSoftware() async throws {
        for id in ["mp4-h264", "mp4-hevc", "mov-prores", "mkv"] {
            // The hardware attempt fails, the software one works: the conversion succeeds.
            #expect(try await encode(id, hardware: true) { $0.hardware } == [true, false], "\(id)")
        }
    }

    @Test func noRetryWhenTheFirstAttemptWorks() async throws {
        #expect(try await encode("mp4-h264", hardware: true) { _ in false } == [true])
    }

    @Test func noRetryWithoutAHardwareEncoderInPlay() async throws {
        // Hardware already off, and formats that never had it: one attempt, and its error is reported.
        for (id, hardware) in [("mp4-h264", false), ("webm", true), ("mp3", true)] {
            let failure = await #expect(throws: FallbackFailure.self, "\(id)") {
                _ = try await self.encode(id, hardware: hardware) { _ in true }
            }
            #expect(failure?.attempts == [hardware], "\(id)")
        }
    }

    @Test func softwareFailureIsReportedWhenBothFail() async throws {
        let failure = await #expect(throws: FallbackFailure.self) {
            _ = try await self.encode("mp4-hevc", hardware: true) { _ in true }
        }
        #expect(failure?.attempts == [true, false])
    }

    @Test func noRetryAfterStop() async throws {
        let runner = Runner()
        let target = try #require(Targets.byID("mp4-h264"))
        let attempts = Attempts()
        await #expect(throws: StoppedError.self) {
            try await Converter.withSoftwareFallback(target, ConvSettings(), runner: runner) { s in
                attempts.add(s.hardware)
                runner.cancel()
                throw StoppedError()
            }
        }
        #expect(attempts.all == [true])
    }
}

/// The `hardware` setting of each encode attempt, in order.
final class Attempts: @unchecked Sendable {
    private var values: [Bool] = []
    private let lock = NSLock()
    func add(_ hardware: Bool) { lock.withLock { values.append(hardware) } }
    var all: [Bool] { lock.withLock { values } }
}
