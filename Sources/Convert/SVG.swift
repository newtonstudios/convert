import AppKit
import UniformTypeIdentifiers
import zlib

/// SVG drawings. ImageIO doesn't read them, so AppKit draws them (NSImage, through CoreSVG).
///
/// The drawing is handed over as bytes, not as a file, and nothing it points at is loaded: no web
/// addresses, no other files, no XML entities. A picture it places from elsewhere comes out as
/// CoreSVG's "missing image" box; pictures embedded in the file (data: URLs) are drawn.
enum SVG {
    /// The longest edge of a drawing turned into pixels at "Same as source", unless the drawing's own
    /// size is bigger. An SVG has no pixels of its own and is mostly drawn for any size: a 32 × 32 icon
    /// as a 32 × 32 JPEG is rarely what anyone wants.
    static let minimumEdge = 1024
    /// … and at most this, however big the drawing says it is.
    static let maximumEdge = 8192
    /// A compressed .svgz larger than this once unpacked is refused (no real drawing is).
    static let maximumUnpacked = 64 << 20

    static func isSVG(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .svg) == true
    }

    /// Reads a drawing. Its size, in points, is the SVG's width and height (or its viewBox).
    static func load(_ url: URL) throws -> NSImage {
        var data: Data
        do { data = try Data(contentsOf: url) } catch { throw ConvertError("Couldn't read this image") }
        if data.starts(with: [0x1F, 0x8B]) { data = try gunzip(data) }  // .svgz
        guard let image = NSImage(data: data), image.representations.first != nil else {
            throw ConvertError("Couldn't read this SVG drawing")
        }
        guard image.size.width > 0, image.size.height > 0, image.size.width.isFinite, image.size.height.isFinite
        else { throw ConvertError("This SVG drawing has no size") }
        return image
    }

    /// The pixel size to draw at: the longest edge is `maxSize` when one is chosen (a drawing scales up
    /// as cleanly as down), otherwise the drawing's own size kept between `minimumEdge` and `maximumEdge`.
    static func pixelSize(of size: CGSize, maxSize: Int) -> (width: Int, height: Int) {
        let longest = max(size.width, size.height)
        let edge = maxSize > 0 ? Double(maxSize) : min(max(longest, Double(minimumEdge)), Double(maximumEdge))
        let scale = edge / longest
        return (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
    }

    /// Draws into pixels, on white when `flatten` (for formats without transparency).
    static func render(_ image: NSImage, maxSize: Int, flatten: Bool) throws -> CGImage {
        let (w, h) = pixelSize(of: image.size, maxSize: maxSize)
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: (flatten ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)
        else { throw ConvertError("This SVG drawing is too big to convert") }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        if flatten {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(rect)
        }
        draw(image, in: ctx, rect)
        guard let out = ctx.makeImage() else { throw ConvertError("Couldn't draw this SVG") }
        return out
    }

    /// Writes a one-page PDF the size of the drawing, keeping it as vectors and text.
    static func writePDF(_ image: NSImage, to out: URL) throws {
        var box = CGRect(origin: .zero, size: image.size)
        guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else {
            throw ConvertError(
                "Couldn't save to “\(OutputFolder.name(of: out.deletingLastPathComponent()))”: "
                    + "that folder can't be written to")
        }
        ctx.beginPDFPage(nil)
        draw(image, in: ctx, box)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    private static func draw(_ image: NSImage, in ctx: CGContext, _ rect: CGRect) {
        // AppKit draws into the current context, which is per thread.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// Unpacks gzip (.svgz), refusing anything that unpacks to more than `maximumUnpacked` bytes.
    static func gunzip(_ data: Data) throws -> Data {
        let damaged = ConvertError("Couldn't read this SVG drawing: the compressed data is damaged")
        var stream = z_stream()
        // 16 + MAX_WBITS: a gzip header and trailer around the deflate data.
        guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw damaged }
        defer { inflateEnd(&stream) }
        var input = [UInt8](data)
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        var status = Z_OK
        try input.withUnsafeMutableBufferPointer { inBuf in
            stream.next_in = inBuf.baseAddress
            stream.avail_in = uInt(inBuf.count)
            while status != Z_STREAM_END {
                try chunk.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = uInt(outBuf.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END else { throw damaged }
                    out.append(outBuf.baseAddress!, count: outBuf.count - Int(stream.avail_out))
                }
                if out.count > maximumUnpacked { throw ConvertError("This SVG drawing is too big to convert") }
                if status == Z_OK, stream.avail_in == 0, stream.avail_out != 0 { throw damaged }  // cut short
            }
        }
        return out
    }
}
