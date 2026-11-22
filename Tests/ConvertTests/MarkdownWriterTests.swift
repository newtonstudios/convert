import AppKit
import Foundation
import Testing

@testable import Convert

/// Styled text → Markdown. Like the renderer's tests, these compare the whole output.
struct MarkdownWriterTests {
    /// Some text in Helvetica (Menlo for code), 12 points unless given.
    private func t(
        _ s: String, size: CGFloat = 12, bold: Bool = false, italic: Bool = false, code: Bool = false,
        link: String? = nil, lists: [NSTextList] = []
    ) -> NSAttributedString {
        var font = NSFont(name: code ? "Menlo" : "Helvetica", size: size)!
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if let link { attrs[.link] = URL(string: link)! }
        if !lists.isEmpty {
            let style = NSMutableParagraphStyle()
            style.textLists = lists
            attrs[.paragraphStyle] = style
        }
        return NSAttributedString(string: s, attributes: attrs)
    }

    private func md(_ parts: NSAttributedString...) -> String {
        let text = NSMutableAttributedString()
        for part in parts { text.append(part) }
        return MarkdownWriter.markdown(from: text)
    }

    private let body = "Body text that is long enough to set the body size of the page.\n"

    // MARK: Headings

    @Test func headingsBySize() {
        let out = md(
            t("Title\n", size: 24, bold: true), t("Section\n", size: 15), t("Detail\n", size: 13.5), t(body),
            t("Barely larger\n", size: 13))
        #expect(
            out == "# Title\n\n## Section\n\n### Detail\n\n\(body)\nBarely larger\n")
    }

    @Test func longOrFinishedSentencesAreNotHeadings() {
        let out = md(t("A big sentence.\n", size: 24), t(body))
        #expect(out == "A big sentence.\n\n\(body)")
    }

    @Test func boldParagraphAtBodySizeStaysBold() {
        #expect(md(t("Important\n", bold: true), t(body)) == "**Important**\n\n\(body)")
    }

    // MARK: Emphasis and code

    @Test func boldItalicAndBoth() {
        let out = md(
            t("Some "), t("bold", bold: true), t(", "), t("it", italic: true), t(" and "),
            t("both", bold: true, italic: true), t("."))
        #expect(out == "Some **bold**, *it* and ***both***.\n")
    }

    @Test func spacesStayOutsideTheMarkers() {
        let out = md(t("a"), t(" bold ", bold: true), t("b"), t(" ", italic: true), t("c"))
        #expect(out == "a **bold** b c\n")
    }

    @Test func runsInTheSameStyleAreOne() {
        // Two fonts, both bold, with a plain space between them.
        let other = NSAttributedString(
            string: "two",
            attributes: [
                .font: NSFontManager.shared.convert(NSFont(name: "Times", size: 12)!, toHaveTrait: .boldFontMask)
            ])
        #expect(md(t("one", bold: true), t(" "), other) == "**one two**\n")
    }

    @Test func codeSpans() {
        #expect(md(t("Run "), t("ls -la", code: true), t(" now")) == "Run `ls -la` now\n")
        #expect(md(t("a`b", code: true)) == "``a`b``\n")
        #expect(md(t("`tick", code: true)) == "`` `tick ``\n")
    }

    @Test func markdownSyntaxInTheTextIsEscaped() {
        #expect(
            md(t("Not *stars* or _under_ or [brackets] or \\ or `ticks`"))
                == "Not \\*stars\\* or \\_under\\_ or \\[brackets\\] or \\\\ or \\`ticks\\`\n")
        #expect(md(t("# not a heading")) == "\\# not a heading\n")
        #expect(md(t("> not a quote\n+ not a list")) == "\\> not a quote\n\n\\+ not a list\n")
        #expect(md(t("2024. A good year")) == "2024\\. A good year\n")
        #expect(md(t("*", code: true)) == "`*`\n")
    }

    // MARK: Links

    @Test func webLinksAreKept() {
        #expect(
            md(t("See "), t("the site", link: "https://example.com/a(b)"))
                == "See [the site](https://example.com/a%28b%29)\n")
        #expect(md(t("mail", link: "mailto:me@example.com")) == "[mail](mailto:me@example.com)\n")
    }

    @Test func fileLinksLoseTheLinkButKeepTheText() {
        #expect(md(t("See "), t("my notes", link: "file:///Users/me/notes.txt")) == "See my notes\n")
    }

    // MARK: Lists

    @Test func listsFromTheParagraphStyle() {
        let bullets = NSTextList(markerFormat: .disc, options: 0)
        let numbers = NSTextList(markerFormat: .decimal, options: 0)
        numbers.startingItemNumber = 3
        let out = md(
            t("Before\n"), t("\t•\tone\n", lists: [bullets]), t("\t•\ttwo\n", lists: [bullets]),
            t("\t3\tthree\n", lists: [bullets, numbers]), t("\t4\tfour\n", lists: [bullets, numbers]),
            t("back\n", lists: [bullets]), t("After\n"))
        #expect(out == "Before\n\n- one\n- two\n  3. three\n  4. four\n- back\n\nAfter\n")
    }

    @Test func nestedUnderANumberIsIndentedPastIt() {
        let numbers = NSTextList(markerFormat: .decimal, options: 0)
        let bullets = NSTextList(markerFormat: .hyphen, options: 0)
        let out = md(t("first\n", lists: [numbers]), t("inner\n", lists: [numbers, bullets]))
        #expect(out == "1. first\n   - inner\n")
    }

    @Test func listsWrittenIntoTheText() {
        let out = md(t("• one\n◦two\n- three\n1. four\n2) five\n3.1 not a list item\n"))
        #expect(out == "- one\n- two\n- three\n1. four\n2) five\n\n3.1 not a list item\n")
    }

    @Test func importedMarkersWithoutAListUseTheIndent() {
        let style = NSMutableParagraphStyle()
        style.headIndent = 72
        let nested = NSAttributedString(
            string: "\t3\tthree\n", attributes: [.paragraphStyle: style, .font: NSFont(name: "Helvetica", size: 12)!])
        #expect(md(t("\t•\tone\n"), nested) == "- one\n  3. three\n")
    }

    // MARK: Everything else

    @Test func attachmentsAreDropped() {
        let picture = NSAttributedString(attachment: NSTextAttachment())
        #expect(md(t("Before "), picture, t(" after\n"), picture, t("\n")) == "Before  after\n")
    }

    @Test func endsWithOneNewline() {
        #expect(md(t("Text\n\n\n")) == "Text\n")
        #expect(md(t("  \n\n")) == "")
    }

    @Test func lineBreaksWithinAParagraph() {
        #expect(md(t("one\u{2028}- two")) == "one\\\n\\- two\n")
    }

    @Test func plainText() {
        let out = MarkdownWriter.markdown(fromPlainText: "Title\r\n\r\n# not *bold*\nnext line\n   \n- dash\n")
        #expect(out == "Title\n\n\\# not \\*bold\\*\\\nnext line\n\n\\- dash\n")
    }

    @Test func codeBlockFenceIsLongerThanAnyInside() {
        #expect(MarkdownWriter.codeBlock("let a = 1\n", language: "swift") == "```swift\nlet a = 1\n```\n")
        #expect(MarkdownWriter.codeBlock("x = ````y````") == "`````\nx = ````y````\n`````\n")
    }
}

/// Documents → Markdown, through the same steps as in the app. Each test works in a fresh
/// temporary folder (cleaned up in `deinit`).
///
/// One test at a time: each waits for textutil on a test thread, and several at once kept the
/// Stop tests' timers from running while the font tests had the other threads busy.
@Suite(.serialized)
final class DocumentMarkdownTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String, _ contents: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func convert(_ input: URL) throws -> String {
        try String(contentsOf: try DocConv.markdown(input, runner: Runner()), encoding: .utf8)
    }

    private var files: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? []
    }

    @Test func markdownSurvivesARoundTripThroughRichText() throws {
        let source = """
            # Title

            ## Section

            Some **bold**, *italic* and `code`, plus a [link](https://example.com/page).

            - one
            - two
              1. inner
            """
        // As the app makes HTML of Markdown, styles included; textutil then reads the HTML.
        let html = try file("sample.html", Markdown.document(body: Markdown.toHTML(source), title: "sample"))
        let out = try convert(html)
        #expect(out.hasPrefix("# Title\n\n## Section\n\n"))
        #expect(out.contains("Some **bold**, *italic* and `code`, plus a [link](https://example.com/page)."))
        #expect(out.contains("- one\n- two\n  1. inner\n"))
        #expect(out.hasSuffix("\n") && !out.hasSuffix("\n\n"))
        #expect(files == ["sample.html", "sample.md"])  // The temporary RTF is gone again.
    }

    @Test func markdownIsCopiedUnchanged() throws {
        let source = "# Notes\n\nKept *exactly* as written.  \n"
        let input = try file("notes.md", source)
        #expect(try convert(input) == source)
        #expect(files == ["notes 2.md", "notes.md"])
    }

    @Test func plainTextIsEscaped() throws {
        #expect(
            try convert(try file("notes.txt", "# Not a heading\n\n*Not italic*\n"))
                == "\\# Not a heading\n\n\\*Not italic\\*\n")
    }

    @Test func sourceCodeIsOneCodeBlock() throws {
        let code = "let s = \"```\"\nprint(s)\n"
        #expect(try convert(try file("main.swift", code)) == "````swift\nlet s = \"```\"\nprint(s)\n````\n")
    }

    @Test func failedConversionLeavesNoFile() throws {
        // The original vanished before its turn came (a batch can take a while).
        for name in ["gone.docx", "gone.txt"] {
            #expect(throws: (any Error).self, "\(name)") { try self.convert(self.dir.appendingPathComponent(name)) }
        }
        #expect(files == [])
    }
}
