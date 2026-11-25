import Foundation
import ImageIO
import Network
import Testing

@testable import Convert

/// SVG drawings, which ImageIO can't read: drawn by AppKit, at a sensible size, without reaching
/// the network or other files.
final class SVGTests {
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

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// 200 × 100 from its viewBox alone: blue on the left half, red on the right, transparent around a margin.
    private let drawing = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100">
          <rect x="10" y="10" width="90" height="80" fill="#00f"/>
          <rect x="100" y="10" width="90" height="80" style="fill: red"/>
        </svg>
        """

    private func convert(_ input: URL, to id: String, maxSize: Int = 0) async throws -> URL {
        var s = ConvSettings()
        s.maxSize = maxSize
        let target = try #require(Targets.byID(id), "no target \(id)")
        let outputs = try await Converter.convert(input, to: target, settings: s, runner: Runner()) { _ in }
        return try #require(outputs.first)
    }

    private func image(_ url: URL) throws -> CGImage {
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    /// The colour at a point given as a fraction of the width and height from the top left, as RGBA.
    private func pixel(_ img: CGImage, _ x: Double, _ y: Double) throws -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(
            CGContext(
                data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let px = (x * Double(img.width)).rounded(.down)
        let py = (y * Double(img.height)).rounded(.down)
        // Shift the image so that pixel lands on the context's only one (CG's origin is the bottom left).
        ctx.draw(
            img,
            in: CGRect(x: -px, y: py - Double(img.height) + 1, width: Double(img.width), height: Double(img.height)))
        return rgba
    }

    private func isRed(_ p: [UInt8]) -> Bool { p[0] > 200 && p[1] < 60 && p[2] < 60 && p[3] > 200 }
    private func isBlue(_ p: [UInt8]) -> Bool { p[0] < 60 && p[1] < 60 && p[2] > 200 && p[3] > 200 }
    private func isWhite(_ p: [UInt8]) -> Bool { p.allSatisfy { $0 > 240 } }

    // MARK: Pixels

    @Test func convertsToEveryPixelFormat() async throws {
        let input = try file("drawing.svg", drawing)
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        for id in ["jpg", "png", "heic", "avif", "tiff", "gif-img", "bmp"] {
            guard let type = ImageConv.utType(id), writable.contains(type.identifier) else { continue }
            let img = try image(try await convert(input, to: id))
            #expect(img.width == 1024 && img.height == 512, "\(id): \(img.width)×\(img.height)")
            #expect(isBlue(try pixel(img, 0.25, 0.5)), "\(id)")
            #expect(isRed(try pixel(img, 0.75, 0.5)), "\(id)")
        }
    }

    @Test func transparencyIsKeptOrFlattenedOntoWhite() async throws {
        let input = try file("drawing.svg", drawing)
        let png = try image(try await convert(input, to: "png"))
        #expect(try pixel(png, 0.01, 0.01)[3] == 0)
        let jpg = try image(try await convert(input, to: "jpg"))
        #expect(isWhite(try pixel(jpg, 0.01, 0.01)))
    }

    @Test func sizeComesFromTheDrawing() async throws {
        // Small drawings (icons) come out at a useful size, huge ones at a sane one, and a chosen
        // size is met exactly, up or down: a drawing has no pixels of its own to lose.
        #expect(SVG.pixelSize(of: CGSize(width: 32, height: 32), maxSize: 0) == (1024, 1024))
        #expect(SVG.pixelSize(of: CGSize(width: 1600, height: 1200), maxSize: 0) == (1600, 1200))
        #expect(SVG.pixelSize(of: CGSize(width: 200_000, height: 100_000), maxSize: 0) == (8192, 4096))
        #expect(SVG.pixelSize(of: CGSize(width: 32, height: 16), maxSize: 512) == (512, 256))
        #expect(SVG.pixelSize(of: CGSize(width: 1600, height: 1200), maxSize: 512) == (512, 384))
        #expect(SVG.pixelSize(of: CGSize(width: 1000, height: 1), maxSize: 0) == (1024, 1))

        // width/height win over the viewBox; units are converted (1in = 72pt).
        let sized = try file(
            "sized.svg", #"<svg xmlns="http://www.w3.org/2000/svg" width="2in" height="1in" viewBox="0 0 20 10"/>"#)
        #expect(try SVG.load(sized).size == CGSize(width: 144, height: 72))
        let chosen = try image(try await convert(try file("drawing.svg", drawing), to: "png", maxSize: 512))
        #expect(chosen.width == 512 && chosen.height == 256)
    }

    // MARK: PDF

    @Test func pdfKeepsTheDrawingAsVectors() async throws {
        let out = try await convert(try file("drawing.svg", drawing), to: "pdf-img")
        let pdf = try #require(CGPDFDocument(out as CFURL))
        #expect(pdf.numberOfPages == 1)
        let page = try #require(pdf.page(at: 1))
        #expect(page.getBoxRect(.mediaBox) == CGRect(x: 0, y: 0, width: 200, height: 100))
        let bytes = try Data(contentsOf: out)
        #expect(bytes.range(of: Data("/Subtype /Image".utf8)) == nil, "the drawing was turned into pixels")
    }

    // MARK: Files

    @Test func compressedDrawingsAreRead() async throws {
        let plain = try file("drawing.svg", drawing)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-k", plain.path]
        try gzip.run()
        gzip.waitUntilExit()
        let svgz = dir.appendingPathComponent("packed.svgz")
        try FileManager.default.moveItem(at: plain.appendingPathExtension("gz"), to: svgz)
        let img = try image(try await convert(svgz, to: "png"))
        #expect(img.width == 1024 && img.height == 512)
        #expect(isRed(try pixel(img, 0.75, 0.5)))

        // Cut short: refused, not drawn half.
        let cut = dir.appendingPathComponent("cut.svgz")
        let packed = try Data(contentsOf: svgz)
        try packed.prefix(packed.count / 2).write(to: cut)
        #expect(throws: ConvertError.self) { try SVG.load(cut) }
    }

    @Test func unreadableDrawingsFailClearlyAndLeaveNothing() async throws {
        let inputs = [
            try file("junk.svg", "not a drawing at all"),
            try file("empty.svg", ""),
            try file("broken.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><rect"),
        ]
        let before = contents
        for input in inputs {
            await #expect(throws: ConvertError.self, "\(input.lastPathComponent)") {
                _ = try await self.convert(input, to: "jpg")
            }
        }
        #expect(contents == before)
    }

    @Test func referencesAreNeitherFetchedNorDrawn() async throws {
        // An SVG can point at web addresses and other files. Converting it must reach neither.
        let listener = try await Listener()
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let secret = elsewhere.appendingPathComponent("secret.png")
        try writeGreenPNG(to: secret)
        try FileManager.default.copyItem(at: secret, to: dir.appendingPathComponent("next to it.png"))

        let web = "http://127.0.0.1:\(listener.port)"
        let references = [
            "\(web)/picture.png", secret.absoluteString, secret.path, "next%20to%20it.png", "next to it.png",
        ]
        for (n, reference) in references.enumerated() {
            let input = try file(
                "drawing \(n).svg",
                """
                <?xml version="1.0"?>
                <!DOCTYPE svg [<!ENTITY remote SYSTEM "\(web)/entity.txt">]>
                <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="8" height="8">
                  <style>@import url(\(web)/style.css); rect { fill: url(\(web)/paint.svg#p) white; }</style>
                  <rect width="8" height="8" fill="white"/>
                  <use href="\(web)/sprite.svg#a"/>
                  <image width="8" height="8" xlink:href="\(reference)"/>
                  <image width="8" height="8" href="\(reference)"/>
                  <text y="8">&remote;</text>
                </svg>
                """)
            let img = try image(try await convert(input, to: "png"))
            let centre = try pixel(img, 0.5, 0.5)
            let green = centre[1] > 200 && centre[0] < 60 && centre[2] < 60
            #expect(!green, "\(reference) was drawn into the picture")
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(listener.connections == 0)
    }

    private func writeGreenPNG(to url: URL) throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        try ImageConv.write(try #require(ctx.makeImage()), to: url, type: .png, label: "PNG", props: [:])
    }
}

/// A local TCP port that counts the connections made to it (and closes them).
private final class Listener: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var connections = 0
        var started = false
    }

    private let listener: NWListener
    private let state: State
    let port: UInt16

    var connections: Int { state.lock.withLock { state.connections } }

    init() async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let state = State()
        listener.newConnectionHandler = { connection in
            state.lock.withLock { state.connections += 1 }
            connection.cancel()
        }
        let ready: Bool = await withCheckedContinuation { cont in
            listener.stateUpdateHandler = { update in
                let result: Bool? =
                    switch update {
                    case .ready: true
                    case .failed, .cancelled: false
                    default: nil
                    }
                guard let result else { return }
                let first = state.lock.withLock {
                    defer { state.started = true }
                    return !state.started
                }
                if first { cont.resume(returning: result) }
            }
            listener.start(queue: .global())
        }
        guard ready, let port = listener.port?.rawValue else {
            listener.cancel()
            throw ConvertError("Couldn't listen on a local port")
        }
        self.listener = listener
        self.state = state
        self.port = port
    }

    deinit {
        listener.cancel()
    }
}
