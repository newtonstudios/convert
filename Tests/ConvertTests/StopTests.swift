import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import Convert

/// Stop works for every kind of conversion, and a stopped or failed one leaves nothing half-written behind.
final class StopTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private var contents: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? []
    }

    /// A PDF with one page per given size, in points.
    private func makePDF(_ name: String = "doc.pdf", pages: [CGSize]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let context = try #require(CGContext(url as CFURL, mediaBox: nil, nil))
        for (i, size) in pages.enumerated() {
            var box = CGRect(origin: .zero, size: size)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Page \(i + 1)"))
            context.textPosition = CGPoint(x: 10, y: 10)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func makePNG(_ name: String = "photo.png") throws -> URL {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let url = dir.appendingPathComponent(name)
        try ImageConv.write(try #require(context.makeImage()), to: url, type: .png, label: "PNG", props: [:])
        return url
    }

    private let page = CGSize(width: 200, height: 200)

    // MARK: PDF → images

    @Test func pdfPagesConvertIntoAFolder() throws {
        let input = try makePDF(pages: [page, page, page])
        let target = try #require(Targets.byID("pdf-png"))
        let outputs = try PDFConv.convert(input, target, ConvSettings(), runner: Runner()) { _ in }
        #expect(outputs.map(\.lastPathComponent) == ["doc pages"])
        let pages = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("doc pages").path)
        #expect(pages.sorted() == ["page 1.png", "page 2.png", "page 3.png"])
    }

    @Test func stoppingPDFPagesEndsWithinOnePageAndRemovesTheFolder() throws {
        let input = try makePDF(pages: Array(repeating: page, count: 5))
        let target = try #require(Targets.byID("pdf-png"))
        let runner = Runner()
        let rendered = Counter()
        #expect(throws: StoppedError.self) {
            // Stop arrives while the first page is being finished.
            try PDFConv.convert(input, target, ConvSettings(), runner: runner) { _ in
                rendered.increment()
                runner.cancel()
            }
        }
        #expect(rendered.value == 1)
        #expect(contents == ["doc.pdf"])
    }

    @Test func pdfPagesFailingPartwayRemovesTheFolder() throws {
        // The second page is too small to have a single pixel, so it can't be rendered.
        let input = try makePDF(pages: [page, CGSize(width: 0.01, height: 0.01), page])
        let target = try #require(Targets.byID("pdf-jpg"))
        let rendered = Counter()
        let error = #expect(throws: ConvertError.self) {
            try PDFConv.convert(input, target, ConvSettings(), runner: Runner()) { _ in rendered.increment() }
        }
        #expect(error?.message == "Page 2 has no size")
        #expect(rendered.value == 1)
        #expect(contents == ["doc.pdf"])
    }

    @Test func stoppedSinglePagePDFLeavesNoFile() throws {
        let input = try makePDF(pages: [page])
        let runner = Runner()
        runner.cancel()
        for id in ["pdf-png", "pdf-txt"] {
            let target = try #require(Targets.byID(id))
            #expect(throws: StoppedError.self) {
                try PDFConv.convert(input, target, ConvSettings(), runner: runner) { _ in }
            }
        }
        #expect(contents == ["doc.pdf"])
    }

    // MARK: Images and documents

    @Test func stoppedImageConversionLeavesNoFile() throws {
        let input = try makePNG()
        let runner = Runner()
        runner.cancel()
        let target = try #require(Targets.byID("jpg"))
        #expect(throws: StoppedError.self) { try ImageConv.convert(input, target, ConvSettings(), runner: runner) }
        #expect(contents == ["photo.png"])

        // The same call goes through once Stop is cleared for the next batch.
        runner.reset()
        let out = try ImageConv.convert(input, target, ConvSettings(), runner: runner)
        #expect(out.lastPathComponent == "photo.jpg")
        #expect(contents == ["photo.jpg", "photo.png"])
    }

    @Test func stoppedDocumentConversionLeavesNoFile() throws {
        let input = dir.appendingPathComponent("notes.txt")
        try "Some notes.\n".write(to: input, atomically: true, encoding: .utf8)
        let runner = Runner()
        runner.cancel()
        let target = try #require(Targets.byID("rtf"))
        #expect(throws: StoppedError.self) { try DocConv.textutil(input, target, runner: runner) }
        #expect(contents == ["notes.txt"])
    }

    @Test func failedDocumentConversionLeavesNoFile() throws {
        // The original vanished before its turn came (a batch can take a while).
        let input = dir.appendingPathComponent("gone.txt")
        let target = try #require(Targets.byID("rtf"))
        #expect(throws: ConvertError.self) { try DocConv.textutil(input, target, runner: Runner()) }
        #expect(contents == [])
    }

    // MARK: The whole conversion, and external tools

    @Test func stoppedConversionsThrowStoppedForEveryKind() async throws {
        let png = try makePNG()
        let pdf = try makePDF(pages: [page, page])
        let text = dir.appendingPathComponent("notes.txt")
        try "Some notes.\n".write(to: text, atomically: true, encoding: .utf8)
        let before = contents
        let runner = Runner()
        runner.cancel()
        for (input, id) in [
            (png, "heic"), (pdf, "pdf-png"), (pdf, "pdf-txt"), (text, "docx"), (text, "pdf-doc"), (text, "md"),
        ] {
            let target = try #require(Targets.byID(id))
            await #expect(throws: StoppedError.self, "\(id)") {
                try await Converter.convert(input, to: target, settings: ConvSettings(), runner: runner) { _ in }
            }
        }
        #expect(contents == before)
    }

    @Test func stopKillsARunningTool() async throws {
        let runner = Runner()
        let started = Date()
        Task {
            try await Task.sleep(for: .milliseconds(200))
            runner.cancel()
        }
        await #expect(throws: StoppedError.self) {
            try await runner.run("/bin/sleep", ["30"], duration: 0) { _ in }
        }
        #expect(Date().timeIntervalSince(started) < 10)
        // And a tool isn't even started once Stop was pressed.
        await #expect(throws: StoppedError.self) {
            try await runner.run("/usr/bin/true", [], duration: 0) { _ in }
        }
    }

    @Test func aFailingToolReportsItsLastErrorLine() async throws {
        let error = await #expect(throws: ConvertError.self) {
            try await Runner().run("/bin/sh", ["-c", "echo first >&2; echo 'the reason' >&2; exit 3"], duration: 0) {
                _ in
            }
        }
        #expect(error?.message == "the reason")
    }
}

/// A count that can be bumped from a `@Sendable` progress callback.
final class Counter: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
