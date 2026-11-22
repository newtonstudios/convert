import AppKit
import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import Convert

/// PDF → Word, OpenDocument and Rich Text. Each test draws its own PDF in a fresh temporary
/// folder (cleaned up in `deinit`), so nothing depends on files elsewhere.
final class PDFWordTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Drawing test PDFs

    /// One line of text at `x`, `y` (measured from the bottom of a 612 × 792 page). Stretched to
    /// `width` when given, as the full lines of a justified paragraph are.
    private struct Text {
        var string: String
        var y: CGFloat
        var x: CGFloat = 72
        var size: CGFloat = 12
        var bold = false
        var color: CGColor?
        var width: CGFloat?
    }

    private static func line(_ t: Text) -> CTLine? {
        guard let font = NSFont(name: t.bold ? "Helvetica-Bold" : "Helvetica", size: t.size) else { return nil }
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if let color = t.color { attrs[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: t.string, attributes: attrs))
        return t.width.flatMap { CTLineCreateJustifiedLine(line, 1, Double($0)) } ?? line
    }

    /// A paragraph as a PDF lays it out: lines 14 points apart, all but the last one as wide as the widest.
    private func paragraph(_ lines: [String], top: CGFloat) -> [Text] {
        let widths = lines.dropLast().compactMap { Self.line(Text(string: $0, y: 0)) }
            .map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        return lines.enumerated().map { i, s in
            Text(string: s, y: top - CGFloat(i) * 14, width: i < lines.count - 1 ? widths.max() : nil)
        }
    }

    private func makePDF(_ pages: [[Text]]) throws -> URL {
        let url = dir.appendingPathComponent("sample.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for page in pages {
            context.beginPDFPage(nil)
            context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))  // Something that isn't text.
            for t in page {
                context.textPosition = CGPoint(x: t.x, y: t.y)
                CTLineDraw(try #require(Self.line(t)), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    // MARK: Converting and reading back

    private func convert(_ input: URL, to id: String, runner: Runner = Runner()) throws -> URL {
        let target = try #require(Targets.byID(id))
        let outputs = try PDFConv.convert(input, target, ConvSettings(), runner: runner) { _ in }
        return try #require(outputs.first)
    }

    private func read(_ url: URL) throws -> NSAttributedString {
        try NSAttributedString(url: url, options: [:], documentAttributes: nil)
    }

    private func paragraphs(_ url: URL) throws -> [String] {
        try read(url).string.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    private static func onMainThread() -> Bool { Thread.isMainThread }

    private func words(_ s: String) -> [Substring] { s.split(whereSeparator: \.isWhitespace) }

    private var files: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? []
    }

    private let first = [
        "The quick brown fox jumps over the lazy dog and then keeps on running far",
        "through the quiet forest until the warm evening light slowly fades away",
        "into the night.",
    ]
    private let second = [
        "A second paragraph starts here, after a gap, and it has a few more words",
        "to fill the line.",
    ]

    // MARK: Tests

    @Test func linesBecomeParagraphsWithEveryWordInOrder() throws {
        let input = try makePDF([paragraph(first, top: 700) + paragraph(second, top: 640)])
        let out = try convert(input, to: "pdf-docx")
        let found = try paragraphs(out)
        #expect(found.count == 2)
        #expect(found.map(words) == [first, second].map { words($0.joined(separator: " ")) })
    }

    @Test func largerHeadingIsItsOwnParagraph() throws {
        let heading = Text(string: "Introduction", y: 720, size: 20, bold: true)
        let input = try makePDF([[heading] + paragraph(first, top: 700)])
        let found = try paragraphs(try convert(input, to: "pdf-docx"))
        #expect(found.first == "Introduction")
        #expect(found.count == 2)
    }

    @Test func hyphenAtLineEndJoinsWithoutSpace() throws {
        let lines = [
            "Every line of this paragraph is long enough to run across the page until exam-",
            "ple words follow on the next line.",
        ]
        let input = try makePDF([paragraph(lines, top: 700)])
        let text = try paragraphs(try convert(input, to: "pdf-docx")).joined(separator: "\n")
        #expect(text.contains("exam-ple words"))
        #expect(!text.contains("exam- ple"))
    }

    @Test func bulletsEachStartAParagraph() throws {
        let items = ["• \(first[0])", "• \(first[1])", "• \(second[0])"]
        let widths = items.compactMap { Self.line(Text(string: $0, y: 0)) }
            .map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        let lines = items.enumerated().map { Text(string: $1, y: 700 - CGFloat($0) * 14, width: widths.max()) }
        let found = try paragraphs(try convert(try makePDF([lines]), to: "pdf-docx"))
        #expect(found.count == 3)
        #expect(found.allSatisfy { $0.hasPrefix("•") })
    }

    @Test func eachPageEndsAParagraphAndReportsProgress() throws {
        let input = try makePDF([paragraph(first, top: 700), paragraph(second, top: 700)])
        let target = try #require(Targets.byID("pdf-docx"))
        let seen = Recorder()
        let outputs = try PDFConv.convert(input, target, ConvSettings(), runner: Runner()) { seen.add($0) }
        let found = try paragraphs(try #require(outputs.first))
        #expect(found.map(words) == [first, second].map { words($0.joined(separator: " ")) })
        #expect(seen.values == [0.5, 1])
    }

    @Test(arguments: [
        ("pdf-docx", NSAttributedString.DocumentType.officeOpenXML),
        ("pdf-odt", .openDocument),
        ("pdf-rtf", .rtf),
    ])
    func writesEachFormatOffTheMainThread(id: String, type: NSAttributedString.DocumentType) async throws {
        let input = try makePDF([paragraph(first, top: 700)])
        let target = try #require(Targets.byID(id))
        // As in the app: converted in a detached task, away from the main thread.
        let outputs = try await Task.detached {
            #expect(!Self.onMainThread())
            return try PDFConv.convert(input, target, ConvSettings(), runner: Runner()) { _ in }
        }.value
        let out = try #require(outputs.first)
        #expect(out.pathExtension == target.ext)
        var attrs: NSDictionary?
        let text = try NSAttributedString(
            url: out, options: [.documentType: type], documentAttributes: &attrs)
        #expect(words(text.string) == words(first.joined(separator: " ")))
        let magic = try Data(contentsOf: out).prefix(5)
        #expect(magic.starts(with: type == .rtf ? Data("{\\rtf".utf8) : Data("PK".utf8)))
    }

    @Test func keepsBoldSizeAndColourInRichText() throws {
        let red = CGColor(srgbRed: 0.8, green: 0, blue: 0, alpha: 1)
        let heading = Text(string: "Introduction", y: 720, size: 20, bold: true, color: red)
        let input = try makePDF([[heading] + paragraph(first, top: 690)])
        let text = try read(try convert(input, to: "pdf-rtf"))

        let headingFont = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(headingFont.pointSize == 20)
        #expect(headingFont.fontDescriptor.symbolicTraits.contains(.bold))
        let headingColor = try #require(
            (text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB))
        #expect(abs(headingColor.redComponent - 0.8) < 0.02 && headingColor.greenComponent < 0.02)

        // Body text has no colour of its own: it comes out black, not white in dark mode.
        let body = (text.string as NSString).range(of: "quick")
        let bodyFont = try #require(text.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont)
        #expect(bodyFont.pointSize == 12)
        #expect(!bodyFont.fontDescriptor.symbolicTraits.contains(.bold))
        let bodyColor = try #require(
            (text.attribute(.foregroundColor, at: body.location, effectiveRange: nil) as? NSColor)?
                .usingColorSpace(.sRGB))
        #expect(bodyColor.redComponent < 0.02 && bodyColor.greenComponent < 0.02 && bodyColor.blueComponent < 0.02)
    }

    @Test func markdownHasTheHeadingParagraphsAndList() throws {
        let title = Text(string: "Title", y: 730, size: 20, bold: true)
        let items = ["• \(second[0])", "• \(second[1])"]
        let list = items.enumerated().map { Text(string: $1, y: 600 - CGFloat($0) * 14) }
        let input = try makePDF([[title] + paragraph(first, top: 700) + list])
        let out = try convert(input, to: "pdf-md")
        #expect(out.pathExtension == "md")
        let text = try String(contentsOf: out, encoding: .utf8)
        let blocks = text.components(separatedBy: "\n\n")
        #expect(blocks.count == 3)
        #expect(blocks.first == "# Title")
        #expect(blocks.dropFirst().first.map(words) == words(first.joined(separator: " ")))
        #expect(blocks.last == "- \(second[0])\n- \(second[1])\n")
    }

    @Test func markdownTargetsHaveNoSettings() throws {
        // Nothing under "Advanced": no resolution or paper size applies to text.
        #expect(try #require(Targets.byID("pdf-md")).isPDFText)
        #expect(try #require(Targets.byID("pdf-md")).hasSettings == false)
        #expect(try #require(Targets.byID("md")).hasSettings == false)
    }

    @Test(arguments: ["pdf-docx", "pdf-md"])
    func pdfWithoutTextThrowsAndLeavesNoFile(id: String) throws {
        let input = try makePDF([[]])
        let target = try #require(Targets.byID(id))
        let error = #expect(throws: (any Error).self) {
            try PDFConv.convert(input, target, ConvSettings(), runner: Runner()) { _ in }
        }
        #expect(error?.localizedDescription == "This PDF contains no extractable text")
        #expect(files == ["sample.pdf"])
    }

    @Test func stoppedConversionLeavesNoFile() throws {
        let input = try makePDF([paragraph(first, top: 700)])
        let runner = Runner()
        runner.cancel()
        #expect(throws: StoppedError.self) { try self.convert(input, to: "pdf-rtf", runner: runner) }
        #expect(files == ["sample.pdf"])
    }

    @Test(arguments: ["pdf-docx", "pdf-md"])
    func passwordProtectedPDFThrows(id: String) throws {
        let input = dir.appendingPathComponent("locked.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let info = [kCGPDFContextUserPassword: "secret", kCGPDFContextOwnerPassword: "secret"] as CFDictionary
        let context = try #require(CGContext(input as CFURL, mediaBox: &bounds, info))
        context.beginPDFPage(nil)
        CTLineDraw(try #require(Self.line(Text(string: "Hidden", y: 100))), context)
        context.endPDFPage()
        context.closePDF()
        let error = #expect(throws: (any Error).self) { try self.convert(input, to: id) }
        #expect(error?.localizedDescription == "This PDF is password-protected")
        #expect(files == ["locked.pdf"])
    }

    @Test func unreadableFileThrows() throws {
        let input = dir.appendingPathComponent("broken.pdf")
        try Data("not a pdf".utf8).write(to: input)
        let error = #expect(throws: (any Error).self) { try self.convert(input, to: "pdf-odt") }
        #expect(error?.localizedDescription == "Couldn't open this PDF")
    }
}

/// Collects progress reports, which may arrive from another thread.
private final class Recorder: @unchecked Sendable {
    private var list: [Double] = []
    private let lock = NSLock()
    func add(_ value: Double) { lock.withLock { list.append(value) } }
    var values: [Double] { lock.withLock { list } }
}
