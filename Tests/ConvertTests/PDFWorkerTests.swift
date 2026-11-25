import Foundation
import Testing

@testable import Convert

/// Document → PDF runs in a helper process (`Convert --pdf-worker`) so the window stays responsive.
/// These use stand-in helpers (shell scripts) to check how the app drives one: Stop, failures, and
/// cleanup. The real helper is exercised by the smoke test, which converts documents to PDF.
final class PDFWorkerTests {
    private let dir: URL
    private let input: URL
    private let out: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        input = dir.appendingPathComponent("notes.txt")
        out = dir.appendingPathComponent("notes.pdf")
        try "Some notes.\n".write(to: input, atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A helper that runs `body` with the app's arguments: $1 --pdf-worker, $2 input, $3 output, $4 paper.
    private func worker(_ body: String) throws -> URL {
        let url = dir.appendingPathComponent("worker-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private var pdfExists: Bool { FileManager.default.fileExists(atPath: out.path) }

    @Test func helperGetsTheFilesAndThePaperSize() async throws {
        let echo = try worker(#"echo "$1|$2|$3|$4" > "$3""#)
        try await DocConv.toPDF(input, out, a4: true, runner: Runner(), worker: echo)
        #expect(try String(contentsOf: out, encoding: .utf8) == "--pdf-worker|\(input.path)|\(out.path)|a4\n")
        try FileManager.default.removeItem(at: out)
        try await DocConv.toPDF(input, out, a4: false, runner: Runner(), worker: echo)
        #expect(try String(contentsOf: out, encoding: .utf8).hasSuffix("|letter\n"))
    }

    @Test(.timeLimit(.minutes(1)))
    func stopEndsTheHelperAndRemovesThePartialPDF() async throws {
        // Half a PDF is on disk and the helper is still busy when Stop is pressed.
        let slow = try worker(#"echo "%PDF-1.4 unfinished" > "$3"; exec sleep 30"#)
        let runner = Runner()
        let started = Date()
        Task {
            while !FileManager.default.fileExists(atPath: self.out.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
            runner.cancel()
        }
        await #expect(throws: StoppedError.self) {
            try await DocConv.toPDF(self.input, self.out, a4: true, runner: runner, worker: slow)
        }
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(!pdfExists)
    }

    @Test func helperIsNotStartedAfterStop() async throws {
        let marker = dir.appendingPathComponent("started")
        let touch = try worker(#"touch "\#(marker.path)"; echo pdf > "$3""#)
        let runner = Runner()
        runner.cancel()
        await #expect(throws: StoppedError.self) {
            try await DocConv.toPDF(self.input, self.out, a4: true, runner: runner, worker: touch)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!pdfExists)
    }

    @Test func failureReportsTheHelpersReasonAndLeavesNoPDF() async throws {
        let failing = try worker(
            #"echo "partial" > "$3"; echo "some log line" >&2; echo "The document is damaged" >&2; exit 1"#)
        let error = await #expect(throws: ConvertError.self) {
            try await DocConv.toPDF(self.input, self.out, a4: true, runner: Runner(), worker: failing)
        }
        #expect(error?.message == "The document is damaged")
        #expect(!pdfExists)
    }

    @Test func aHelperThatWritesNothingIsAFailure() async throws {
        let idle = try worker("exit 0")
        let error = await #expect(throws: ConvertError.self) {
            try await DocConv.toPDF(self.input, self.out, a4: true, runner: Runner(), worker: idle)
        }
        #expect(error?.message == "Couldn't create the PDF")
    }

    @Test(.timeLimit(.minutes(1)))
    func theMainThreadStaysFreeWhileTheHelperWorks() async throws {
        // The helper takes 3 seconds. Meanwhile the main thread (the window) must keep answering;
        // waiting for the helper on it would hold it up for all 3. Other tests lay documents out on
        // the main thread at the same time, which on CI's 3-core Mac costs up to 0.7 s here.
        let slow = try worker(#"sleep 3; echo pdf > "$3""#)
        async let conversion: Void = DocConv.toPDF(input, out, a4: true, runner: Runner(), worker: slow)
        var worst = 0.0
        for _ in 0..<10 {
            let asked = Date()
            await MainActor.run {}
            worst = max(worst, Date().timeIntervalSince(asked))
            try await Task.sleep(for: .milliseconds(50))
        }
        try await conversion
        #expect(worst < 2, "the main thread was held up for \(worst)s")
        #expect(pdfExists)
    }
}
