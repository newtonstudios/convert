import AppKit
import CoreGraphics
import Foundation
import PDFKit

enum DocConv {
    /// Formats macOS's textutil reads natively; Markdown is rendered to HTML first,
    /// anything else (source code, logs…) goes in as plain text.
    static let textutilInputs: Set<String> = [
        "txt", "text", "rtf", "rtfd", "html", "htm", "doc", "docx", "odt", "wordml", "webarchive", "xml",
    ]

    static func isPlain(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "txt" || ext == "text" || !textutilInputs.contains(ext)
    }

    /// Markdown becomes a styled HTML file in a temp folder; everything else is used as is.
    private static func source(for input: URL) throws -> (url: URL, cleanup: () -> Void) {
        guard Markdown.isMarkdown(input) else { return (input, {}) }
        let html = try Markdown.renderToTempHTML(input)
        return (html, { try? FileManager.default.removeItem(at: html.deletingLastPathComponent()) })
    }

    static func textutil(_ input: URL, _ t: Target, runner: Runner) throws -> URL {
        try runner.checkCancelled()
        let out = try uniqueOutput(for: input, ext: t.ext)
        let src = try source(for: input)
        defer { src.cleanup() }
        do {
            if Markdown.isMarkdown(input), t.ext == "html" {
                try FileManager.default.copyItem(at: src.url, to: out)
            } else {
                var args = ["-convert", t.ext]
                if !textutilInputs.contains(src.url.pathExtension.lowercased()) {
                    args += ["-format", "txt", "-inputencoding", "UTF-8"]
                }
                if t.ext == "txt" || t.ext == "html" { args += ["-encoding", "UTF-8"] }
                args += ["-output", out.path, src.url.path]
                try runSync("/usr/bin/textutil", args)
                // textutil reports success even when it couldn't read the file and wrote nothing.
                guard FileManager.default.fileExists(atPath: out.path) else {
                    throw ConvertError("Couldn't read this document")
                }
            }
            try runner.checkCancelled()
        } catch {
            // Stopped or failed: no half-written or unwanted file stays behind.
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    /// Document → Markdown. Markdown is copied as it is, plain text keeps its words as written,
    /// and source code becomes one code block. Everything else goes to RTF first: textutil reads
    /// every format, and RTF (unlike HTML) can be loaded away from the main thread.
    static func markdown(_ input: URL, runner: Runner) throws -> URL {
        try runner.checkCancelled()
        let ext = input.pathExtension.lowercased()
        let text: String?  // Nil: the file is Markdown already.
        if Markdown.isMarkdown(input) {
            text = nil
        } else if ext == "txt" || ext == "text" {
            text = MarkdownWriter.markdown(fromPlainText: try String(contentsOf: input, encoding: .utf8))
        } else if isPlain(input) {
            text = MarkdownWriter.codeBlock(try String(contentsOf: input, encoding: .utf8), language: ext)
        } else {
            text = MarkdownWriter.markdown(from: try styledText(of: input))
        }
        try runner.checkCancelled()
        let out = try uniqueOutput(for: input, ext: "md")
        do {
            if let text {
                try Data(text.utf8).write(to: out, options: .atomic)
            } else {
                try FileManager.default.copyItem(at: input, to: out)
            }
            try runner.checkCancelled()
        } catch {
            // Stopped or failed: no half-written or unwanted file stays behind.
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    /// The document as styled text, by way of an RTF file in a temp folder that's removed again.
    private static func styledText(of input: URL) throws -> NSAttributedString {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rtf = dir.appendingPathComponent("document.rtf")
        try runSync("/usr/bin/textutil", ["-convert", "rtf", "-output", rtf.path, input.path])
        // textutil reports success even when it couldn't read the file and wrote nothing.
        guard FileManager.default.fileExists(atPath: rtf.path) else {
            throw ConvertError("Couldn't read this document")
        }
        return try NSAttributedString(
            url: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    }

    /// The app's own executable, set at launch. Nil in unit tests, which have no app to start.
    static var worker: URL?

    /// Document → PDF without holding up the window.
    ///
    /// Laying text out on paper needs AppKit's text system, which only works on the main thread,
    /// where a big document would freeze the window for seconds. So the app starts a second copy
    /// of itself to do it (`Convert --pdf-worker`, see main.swift): the window stays responsive,
    /// and Stop simply ends that process. A stopped or failed conversion leaves no partial PDF.
    static func toPDF(
        _ input: URL, _ out: URL, a4: Bool, runner: Runner, worker: URL? = DocConv.worker
    ) async throws {
        do {
            try runner.checkCancelled()
            if let worker {
                let args = ["--pdf-worker", input.path, out.path, a4 ? "a4" : "letter"]
                try await runner.run(worker.path, args, duration: 0) { _ in }
            } else {
                try await MainActor.run { try layOutPDF(input, out, a4: a4) }
            }
            try runner.checkCancelled()
            guard FileManager.default.fileExists(atPath: out.path) else {
                throw ConvertError("Couldn't create the PDF")
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    /// Lays the document out on paper and prints it to PDF. Must run on the main thread (AppKit text system).
    @MainActor
    static func layOutPDF(_ original: URL, _ out: URL, a4: Bool) throws {
        let src = try source(for: original)
        defer { src.cleanup() }
        let input = src.url
        var opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        if isPlain(input) {
            opts[.documentType] = NSAttributedString.DocumentType.plain
            opts[.characterEncoding] = String.Encoding.utf8.rawValue
        }
        let loaded = try NSAttributedString(url: input, options: opts, documentAttributes: nil)
        let text = NSMutableAttributedString(attributedString: loaded)
        let full = NSRange(location: 0, length: text.length)
        // Text without an explicit colour would otherwise follow dark mode and print white.
        text.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if value == nil { text.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        if isPlain(input) {
            text.enumerateAttribute(.font, in: full) { value, range, _ in
                if value == nil { text.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: range) }
            }
        }

        let info = NSPrintInfo()
        info.paperSize = a4 ? NSSize(width: 595.28, height: 841.89) : NSSize(width: 612, height: 792)
        info.topMargin = 56
        info.bottomMargin = 56
        info.leftMargin = 56
        info.rightMargin = 56
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        // Absolute: a URL relative to the current folder makes the print system log CFURL warnings.
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out.absoluteURL

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(text)
        if let lm = view.layoutManager, let tc = view.textContainer {
            lm.ensureLayout(for: tc)
            view.frame.size.height = max(100, lm.usedRect(for: tc).height)
        }

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: out.path) else {
            throw ConvertError("Couldn't create the PDF")
        }
    }
}

enum PDFConv {
    static func convert(
        _ input: URL, _ t: Target, _ s: ConvSettings, runner: Runner,
        progress: @Sendable (Double) -> Void
    ) throws -> [URL] {
        if t.id == "pdf-txt" {
            guard let doc = PDFDocument(url: input) else { throw ConvertError("Couldn't open this PDF") }
            if doc.isLocked { throw ConvertError("This PDF is password-protected") }
            guard let text = doc.string,
                text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) != nil
            else {
                throw ConvertError("This PDF contains no extractable text")
            }
            try runner.checkCancelled()
            let out = try uniqueOutput(for: input, ext: "txt")
            try text.write(to: out, atomically: true, encoding: .utf8)
            return [out]
        }
        if t.isPDFText { return [try document(input, t, runner: runner, progress: progress)] }

        guard let doc = CGPDFDocument(input as CFURL) else { throw ConvertError("Couldn't open this PDF") }
        if doc.isEncrypted && !doc.isUnlocked { throw ConvertError("This PDF is password-protected") }
        let count = doc.numberOfPages
        guard count > 0 else { throw ConvertError("This PDF has no pages") }

        // One page → file next to the PDF. Several → a folder with page 1, page 2, …
        var folder: URL?
        if count > 1 {
            let f = try uniqueFolder(for: input, suffix: " pages")
            try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
            folder = f
        }
        let single = try uniqueOutput(for: input, ext: t.ext)
        let scale = CGFloat(s.pdfDPI) / 72
        let type = ImageConv.utType(t.id)
        var props: [CFString: Any] = [:]
        if t.id == "pdf-jpg" { props[kCGImageDestinationLossyCompressionQuality] = s.imageQuality }

        // Stop takes effect between pages. Stopped or failed partway, the pages written so far are
        // removed again: half a folder of pages would look like a finished conversion.
        let made = folder ?? single
        do {
            for i in 1...count {
                try runner.checkCancelled()
                guard let page = doc.page(at: i) else { continue }
                let box = page.getBoxRect(.cropBox)
                let turned = page.rotationAngle % 180 != 0
                let size = turned ? CGSize(width: box.height, height: box.width) : box.size
                let pw = Int((size.width * scale).rounded())
                let ph = Int((size.height * scale).rounded())
                guard pw > 0, ph > 0 else { throw ConvertError("Page \(i) has no size") }
                guard
                    let ctx = CGContext(
                        data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                else { throw ConvertError("Page \(i) is too large to render") }
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
                ctx.interpolationQuality = .high
                ctx.scaleBy(x: scale, y: scale)
                ctx.concatenate(
                    page.getDrawingTransform(
                        .cropBox, rect: CGRect(origin: .zero, size: size),
                        rotate: 0, preserveAspectRatio: true))
                ctx.drawPDFPage(page)
                guard let img = ctx.makeImage() else { throw ConvertError("Couldn't render page \(i)") }

                let out = folder.map { $0.appendingPathComponent("page \(i)").appendingPathExtension(t.ext) } ?? single
                try ImageConv.write(img, to: out, type: type, label: t.label, props: props)
                progress(Double(i) / Double(count))
            }
        } catch {
            try? FileManager.default.removeItem(at: made)
            throw error
        }
        return [made]
    }

    /// PDF → Word, OpenDocument, Rich Text or Markdown: the text, rebuilt into paragraphs (see
    /// PDFText), with its fonts, sizes and colours (Markdown keeps headings, bold, italic and
    /// lists of those). No images, tables or page layout ("text only").
    static func document(
        _ input: URL, _ t: Target, runner: Runner, progress: @Sendable (Double) -> Void
    ) throws -> URL {
        let text = try styledText(of: input, runner: runner, progress: progress)
        let data: Data
        if t.ext == "md" {
            data = Data(MarkdownWriter.markdown(from: text).utf8)
        } else {
            let types: [String: NSAttributedString.DocumentType] = [
                "docx": .officeOpenXML, "odt": .openDocument, "rtf": .rtf,
            ]
            let attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: types[t.ext] ?? .rtf]
            data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attrs)
        }
        try runner.checkCancelled()
        let out = try uniqueOutput(for: input, ext: t.ext)
        do {
            try data.write(to: out, options: .atomic)
            try runner.checkCancelled()
        } catch {
            // Stopped or failed: no unwanted or half-written file stays behind.
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    /// Every page's paragraphs, one after the other. Stop takes effect between pages.
    private static func styledText(
        of input: URL, runner: Runner, progress: @Sendable (Double) -> Void
    ) throws -> NSAttributedString {
        guard let doc = PDFDocument(url: input) else { throw ConvertError("Couldn't open this PDF") }
        if doc.isLocked { throw ConvertError("This PDF is password-protected") }
        let text = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            try runner.checkCancelled()
            if let page = doc.page(at: i) { text.append(PDFText.paragraphs(on: page)) }
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        guard text.string.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) != nil else {
            throw ConvertError("This PDF contains no extractable text")
        }
        return text
    }
}
