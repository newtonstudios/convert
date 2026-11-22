import AppKit

/// Styled text → Markdown, for documents and PDFs converted to Markdown.
///
/// Styled text has no headings as such, only bigger letters, so a short line clearly larger than
/// the body text is taken for one. Bold, italic and code come from the fonts, links from the
/// text's links, lists from the paragraph style or from a bullet or number at the start.
/// Everything else is escaped, so the Markdown reads the same as the original.
enum MarkdownWriter {
    /// How much larger than the body text a short paragraph has to be to become a heading, per
    /// level. Bold text at the body size stays a bold paragraph: documents use it for emphasis
    /// as often as for headings.
    static let headingLevels: [(scale: CGFloat, marker: String)] = [(1.5, "#"), (1.25, "##"), (1.1, "###")]
    /// Longer than this, it's a paragraph in big letters rather than a heading.
    static let headingMaxLength = 80

    static func markdown(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        var paragraphs: [NSRange] = []
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]
        ) { _, range, _, _ in paragraphs.append(range) }

        let body = mainSize(of: text, in: NSRange(location: 0, length: text.length))
        var blocks: [(text: String, isItem: Bool)] = []
        // Per nesting level, how far the item above indents its text: where a nested item has to start.
        var indents: [Int] = []
        for range in paragraphs {
            if let item = listItem(text, range) {
                let content = trimmed(range, in: string, from: item.skip)
                let line = lineStartsEscaped(inline(text, content))
                guard !line.isEmpty else { continue }
                indents = Array(indents.prefix(item.level))
                let indent = String(repeating: " ", count: indents.reduce(0, +))
                indents += Array(repeating: 2, count: item.level - indents.count) + [item.marker.count + 1]
                blocks.append((indent + item.marker + " " + line, true))
                continue
            }
            indents = []
            let content = trimmed(range, in: string)
            if let marker = headingMarker(text, content, body: body) {
                let line = lineStartsEscaped(inline(text, content, heading: true))
                if !line.isEmpty { blocks.append((marker + " " + line, false)) }
            } else if let number = writtenNumber(string.substring(with: content)) {
                // "1." or "2)" stays as written, so a PDF's numbered list stays one.
                let line = lineStartsEscaped(inline(text, trimmed(content, in: string, from: number.utf16.count)))
                if !line.isEmpty { blocks.append((number + " " + line, true)) }
            } else {
                let line = lineStartsEscaped(inline(text, content))
                if !line.isEmpty { blocks.append((line, false)) }
            }
        }

        var out = ""
        for (i, block) in blocks.enumerated() {
            if i > 0 { out += block.isItem && blocks[i - 1].isItem ? "\n" : "\n\n" }
            out += block.text
        }
        return out.isEmpty ? "" : out + "\n"
    }

    /// Plain text → Markdown: blank lines separate paragraphs, other line breaks stay line breaks,
    /// and nothing in the text turns into formatting.
    static func markdown(fromPlainText text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var paragraphs: [[String]] = [[]]
        for line in normalized.components(separatedBy: "\n") {
            // Indents are dropped: four spaces at the start would make a code block.
            let line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty {
                paragraphs[paragraphs.count - 1].append(lineStartsEscaped(escaped(line)))
            } else if paragraphs.last?.isEmpty == false {
                paragraphs.append([])
            }
        }
        let out = paragraphs.filter { !$0.isEmpty }.map { $0.joined(separator: "\\\n") }.joined(separator: "\n\n")
        return out.isEmpty ? "" : out + "\n"
    }

    /// The text as one fenced code block, with a fence longer than any run of backticks inside it.
    static func codeBlock(_ text: String, language: String = "") -> String {
        let code = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: code) + 1))
        return fence + language + "\n" + code + "\n" + fence + "\n"
    }

    // MARK: Headings and lists

    /// The font size most of the text is in (the smaller one when two are tied).
    static func mainSize(of text: NSAttributedString, in range: NSRange) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: range) { value, r, _ in
            if let font = value as? NSFont { counts[font.pointSize, default: 0] += r.length }
        }
        return counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key ?? 12
    }

    private static func headingMarker(_ text: NSAttributedString, _ range: NSRange, body: CGFloat) -> String? {
        let line = (text.string as NSString).substring(with: range)
        guard line.count <= headingMaxLength, !line.hasSuffix("."), !line.contains("\u{2028}") else { return nil }
        let size = mainSize(of: text, in: range)
        return headingLevels.first { size >= $0.scale * body }?.marker
    }

    /// A list item: its nesting level, its Markdown marker, and how much of the text its old marker takes up.
    private struct Item {
        var level: Int
        var marker: String
        var skip: Int
    }

    private static func listItem(_ text: NSAttributedString, _ range: NSRange) -> Item? {
        let string = text.string as NSString
        let line = string.substring(with: range)
        // The RTF and Word importers can put an item's marker in the text, between two tabs.
        let imported = line.range(of: #"^\t[^\t]{1,8}\t"#, options: .regularExpression).map {
            (marker: String(line[$0].dropFirst().dropLast()), length: line[$0].utf16.count)
        }
        let style = range.length > 0 ? text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) : nil
        let paragraphStyle = style as? NSParagraphStyle

        if let lists = paragraphStyle?.textLists, let list = lists.last {
            let ordered = list.marker(forItemNumber: 1).contains { $0.isLetter || $0.isNumber }
            // itemNumber counts from 1 whatever number the list starts at.
            let number = list.startingItemNumber + text.itemNumber(in: list, at: range.location) - 1
            let marker = ordered ? "\(number)." : "-"
            return Item(level: lists.count - 1, marker: marker, skip: imported?.length ?? 0)
        }
        if let imported {
            // Without a list in the paragraph style (textutil's own Word files), only the indent
            // tells the nesting: Word and textutil indent each level by half an inch more.
            let level = max(0, Int(((paragraphStyle?.headIndent ?? 0) / 36).rounded()) - 1)
            if PDFText.isBulleted(imported.marker + " ") {
                return Item(level: level, marker: "-", skip: imported.length)
            }
            if let digits = imported.marker.range(of: #"^[0-9]{1,9}(?=[.)]?$)"#, options: .regularExpression) {
                return Item(level: level, marker: imported.marker[digits] + ".", skip: imported.length)
            }
            return nil
        }
        let start = trimmed(range, in: string)
        let content = string.substring(with: start)
        guard PDFText.isBulleted(content) else { return nil }
        let bullet = content.first.map { "-–—*".contains($0) } == true ? 2 : content.prefix(1).utf16.count
        return Item(level: 0, marker: "-", skip: start.location - range.location + bullet)
    }

    /// The number a paragraph starts with, when Markdown reads it as a list item ("1." or "2)").
    private static func writtenNumber(_ line: String) -> String? {
        guard PDFText.isNumbered(line), let r = line.range(of: #"^[0-9]{1,9}[.)](?=\s)"#, options: .regularExpression)
        else { return nil }
        return String(line[r])
    }

    // MARK: Inline

    /// A stretch of text in one style.
    private struct Run {
        var text: String
        var bold = false
        var italic = false
        var code = false
        var link: URL?

        func sameStyle(as other: Run) -> Bool {
            bold == other.bold && italic == other.italic && code == other.code && link == other.link
        }
    }

    /// The paragraph's text with its emphasis, code and links. Headings are bold anyway, so
    /// their bold isn't written.
    private static func inline(_ text: NSAttributedString, _ range: NSRange, heading: Bool = false) -> String {
        var runs: [Run] = []
        text.enumerateAttributes(in: range) { attrs, r, _ in
            // Pictures and other attachments can't go into Markdown text.
            let piece = (text.string as NSString).substring(with: r).replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !piece.isEmpty else { return }
            var run = Run(text: piece)
            if let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits {
                run.code = traits.contains(.monoSpace)
                run.bold = traits.contains(.bold) && !heading && !run.code
                run.italic = traits.contains(.italic) && !run.code
            }
            run.link = webLink(attrs[.link])
            // Spaces join the run before them, so "bold, space, bold" is one bold stretch.
            if let last = runs.last, last.sameStyle(as: run) || piece.allSatisfy(isSpace) {
                runs[runs.count - 1].text += piece
            } else {
                runs.append(run)
            }
        }
        return runs.map(write).joined()
    }

    private static func write(_ run: Run) -> String {
        let lead = String(run.text.prefix(while: isSpace))
        guard lead.count < run.text.count else { return lead }
        let trail = String(run.text.reversed().prefix(while: isSpace).reversed())
        let core = String(run.text.dropFirst(lead.count).dropLast(trail.count))
        var out: String
        if run.code {
            out = codeSpan(core)
        } else {
            let marker = run.bold && run.italic ? "***" : run.bold ? "**" : run.italic ? "*" : ""
            out = marker + escaped(core) + marker
        }
        if let link = run.link { out = "[\(out)](\(destination(link)))" }
        // Markers must touch the text, or Markdown doesn't read them as markers.
        return lead + out + trail
    }

    private static func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" || c == "\u{00A0}" }

    /// Only links that work anywhere: a link to a file on this Mac would give away its path.
    private static func webLink(_ value: Any?) -> URL? {
        let url = (value as? URL) ?? (value as? String).flatMap { URL(string: $0) }
        guard let scheme = url?.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }

    /// The URL as a link destination, which ends at a space or an unmatched parenthesis.
    private static func destination(_ url: URL) -> String {
        url.absoluteString.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    }

    private static func codeSpan(_ code: String) -> String {
        let code = code.replacingOccurrences(of: "\u{2028}", with: " ")
        let fence = String(repeating: "`", count: longestBacktickRun(in: code) + 1)
        // A backtick right next to the fence would make the fence longer; a space on each side is dropped again.
        let pad = code.hasPrefix("`") || code.hasSuffix("`") ? " " : ""
        return fence + pad + code + pad + fence
    }

    private static func longestBacktickRun(in s: String) -> Int {
        var longest = 0
        var current = 0
        for c in s {
            current = c == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }

    // MARK: Escaping

    /// Characters that mean something anywhere in a line are escaped; a line break within a
    /// paragraph becomes Markdown's own line break.
    static func escaped(_ s: String) -> String {
        var out = ""
        for c in s {
            if c == "\u{2028}" {
                out += "\\\n"
                continue
            }
            if "\\`*_[]".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// At the start of a line, "#", ">", "+", "-" and "1. " start a heading, quote or list.
    static func lineStartsEscaped(_ s: String) -> String {
        s.components(separatedBy: "\n").map { line in
            if let first = line.first, "#>+-".contains(first) { return "\\" + line }
            if let number = line.range(of: #"^[0-9]{1,9}(?=[.)](\s|$))"#, options: .regularExpression) {
                return line[number] + "\\" + line[number.upperBound...]
            }
            return line
        }.joined(separator: "\n")
    }

    /// The range, from `skip` characters in, without the spaces and tabs at either end.
    private static func trimmed(_ range: NSRange, in string: NSString, from skip: Int = 0) -> NSRange {
        var lo = range.location + skip
        var hi = range.location + range.length
        func space(_ i: Int) -> Bool { [0x20, 0x09, 0xA0].contains(string.character(at: i)) }
        while lo < hi, space(lo) { lo += 1 }
        while hi > lo, space(hi - 1) { hi -= 1 }
        return NSRange(location: lo, length: hi - lo)
    }
}
