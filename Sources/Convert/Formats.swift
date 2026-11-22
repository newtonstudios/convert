import Foundation
import UniformTypeIdentifiers

// MARK: - Input kinds

enum MediaKind: String, CaseIterable {
    case audio, video, image, pdf, document, font

    /// The kind of file this is, going by its name (see `FileTypes` for the list), and by its
    /// contents where the name is ambiguous: `.ts` is a video transport stream, or TypeScript.
    static func of(_ url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if ext == "ts", let head = Sniff.header(of: url), !head.isEmpty,
            !Sniff.isTransportStream(head), Sniff.looksLikeText(head)
        {
            return .document
        }
        if let extra = FileTypes.extraExtensions.first(where: { $0.exts.contains(ext) }) { return extra.kind }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        return FileTypes.contentTypes.first { $0.types.contains { type.conforms(to: $0) } }?.kind
    }

    var outputGroups: Set<OutGroup> {
        switch self {
        case .audio: [.audio]
        case .video: [.video, .audio]
        case .image: [.image]
        case .pdf: [.pdfPages]
        case .document: [.document]
        case .font: [.font]
        }
    }

    var symbol: String {
        switch self {
        case .audio: "waveform"
        case .video: "film"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .font: "textformat"
        }
    }

    var noun: String {
        switch self {
        case .audio: "Audio"
        case .video: "Video"
        case .image: "Image"
        case .pdf: "PDF"
        case .document: "Document"
        case .font: "Font"
        }
    }
}

// MARK: - Accepted file types

/// The one list of what Convert accepts. File-kind detection reads it, the Finder Quick Action
/// sends exactly these types, and a test checks that Resources/Info.plist declares the same ones.
enum FileTypes {
    /// Content type identifiers by kind, in the order detection tries them
    /// (PDF and images before the broader audio/video types, documents last). macOS has no type
    /// for WOFF2; the app bundle declares `org.w3c.woff2` itself.
    static let accepted: [(kind: MediaKind, identifiers: [String])] = [
        (.pdf, ["com.adobe.pdf"]),
        (.image, ["public.image"]),
        (.audio, ["public.audio"]),
        (.video, ["public.movie", "public.audiovisual-content"]),
        (
            .font,
            [
                "public.truetype-ttf-font", "public.opentype-font", "public.truetype-collection-font",
                "public.opentype-collection-font", "org.w3c.woff", "org.w3c.woff2",
            ]
        ),
        (
            .document,
            [
                "public.plain-text", "public.rtf", "com.apple.rtfd", "public.html", "com.apple.webarchive",
                "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
                "org.oasis-open.opendocument.text", "net.daringfireball.markdown",
            ]
        ),
    ]

    /// Extensions macOS has no content type for (or files it under a different one), by kind.
    /// WOFF is one of them since macOS 26.6.
    static let extraExtensions: [(kind: MediaKind, exts: Set<String>)] = [
        (.video, ["mkv", "webm", "avi", "flv", "wmv", "ts", "mts", "m2ts", "3gp", "ogv", "mxf", "vob"]),
        (.audio, ["mka", "opus", "ape", "wv", "tta", "dsf", "dff", "ac3", "dts", "amr", "mp2", "caf"]),
        (.document, ["md", "markdown"]),
        (.font, ["woff", "woff2"]),
    ]

    /// Every accepted content type identifier: what the Quick Action and the app bundle declare.
    static var identifiers: [String] { accepted.flatMap(\.identifiers) }

    /// `accepted` as content types; an identifier this Mac doesn't know is left out.
    static let contentTypes: [(kind: MediaKind, types: [UTType])] = accepted.map { entry in
        (entry.kind, entry.identifiers.compactMap { UTType($0) })
    }
}

// MARK: - Output targets

enum OutGroup: String, CaseIterable {
    case video = "Video"
    case audio = "Audio"
    case image = "Image"
    case document = "Document"
    case pdfPages = "From PDF"
    case font = "Font"
}

struct Target: Identifiable, Hashable {
    let id: String
    let label: String
    let ext: String
    let group: OutGroup
}

enum Targets {
    /// Every format, in menu order. WebP is only offered while cwebp is installed; that's checked
    /// on each use, so it shows up as soon as cwebp does.
    static var all: [Target] { Tools.cwebp == nil ? catalogue.filter { $0.id != "webp" } : catalogue }

    private static let catalogue: [Target] = {
        func t(_ g: OutGroup, _ list: [(String, String, String)]) -> [Target] {
            list.map { Target(id: $0.0, label: $0.1, ext: $0.2, group: g) }
        }
        return t(
            .video,
            [
                ("mp4-h264", "MP4 (H.264)", "mp4"),
                ("mp4-hevc", "MP4 (HEVC / H.265)", "mp4"),
                ("mov-prores", "MOV (ProRes 422)", "mov"),
                ("webm", "WebM (VP9)", "webm"),
                ("mkv", "MKV (H.264)", "mkv"),
                ("mp4-av1", "MP4 (AV1)", "mp4"),
                ("gif", "GIF (animated)", "gif"),
            ])
            + t(
                .audio,
                [
                    ("mp3", "MP3", "mp3"),
                    ("m4a", "M4A (AAC)", "m4a"),
                    ("he-aac", "M4A (HE-AAC, small)", "m4a"),
                    ("wav", "WAV", "wav"),
                    ("aiff", "AIFF", "aiff"),
                    ("flac", "FLAC", "flac"),
                    ("alac", "ALAC (Apple Lossless)", "m4a"),
                    ("opus", "Opus", "opus"),
                    ("ogg", "OGG (Vorbis)", "ogg"),
                    ("wma", "WMA", "wma"),
                    ("ac3", "AC3 (Dolby Digital)", "ac3"),
                    ("wv", "WavPack", "wv"),
                    ("mp2", "MP2", "mp2"),
                ])
            + t(
                .image,
                [
                    ("jpg", "JPEG", "jpg"),
                    ("png", "PNG", "png"),
                    ("heic", "HEIC", "heic"),
                    ("avif", "AVIF", "avif"),
                    ("webp", "WebP", "webp"),
                    ("tiff", "TIFF", "tiff"),
                    ("gif-img", "GIF", "gif"),
                    ("bmp", "BMP", "bmp"),
                    ("pdf-img", "PDF", "pdf"),
                ])
            + t(
                .document,
                [
                    ("pdf-doc", "PDF", "pdf"),
                    ("docx", "Word (DOCX)", "docx"),
                    ("doc", "Word 97–2004 (DOC)", "doc"),
                    ("odt", "OpenDocument (ODT)", "odt"),
                    ("rtf", "Rich Text (RTF)", "rtf"),
                    ("txt", "Plain Text", "txt"),
                    ("html", "HTML", "html"),
                ])
            + t(
                .pdfPages,
                [
                    ("pdf-png", "PNG (one per page)", "png"),
                    ("pdf-jpg", "JPEG (one per page)", "jpg"),
                    ("pdf-docx", "Word (DOCX, text only)", "docx"),
                    ("pdf-odt", "OpenDocument (ODT, text only)", "odt"),
                    ("pdf-rtf", "Rich Text (RTF, text only)", "rtf"),
                    ("pdf-txt", "Plain Text", "txt"),
                ])
            + t(
                .font,
                [
                    ("font-woff2", "WOFF2 (web font)", "woff2"),
                    ("font-woff", "WOFF (web font)", "woff"),
                    // .ttf or .otf, whichever the font inside is.
                    ("font-desktop", "TTF / OTF (desktop font)", "ttf"),
                ])
    }()

    static func byID(_ id: String) -> Target? { all.first { $0.id == id } }

    /// Output groups valid for every selected file.
    static func groups(for kinds: Set<MediaKind>) -> [(OutGroup, [Target])] {
        guard !kinds.isEmpty else { return [] }
        var allowed = Set(OutGroup.allCases)
        for k in kinds { allowed.formIntersection(k.outputGroups) }
        return OutGroup.allCases.filter(allowed.contains).map { g in (g, all.filter { $0.group == g }) }
    }

    /// Sensible first choice for a selection, skipping the format the files are already in.
    static func preferred(for kinds: Set<MediaKind>, sourceExts: Set<String>, among available: [Target]) -> Target? {
        let order: [String]
        switch kinds.count == 1 ? kinds.first : (kinds == [.audio, .video] ? .audio : nil) {
        case .audio: order = ["mp3", "wav", "m4a"]
        case .video: order = ["mp4-h264", "mov-prores"]
        case .image: order = ["jpg", "png"]
        case .pdf: order = ["pdf-png"]
        case .document: order = ["pdf-doc", "docx"]
        case .font: order = ["font-woff2", "font-desktop"]
        default: order = []
        }
        for id in order {
            if let t = available.first(where: { $0.id == id }), !sourceExts.contains(t.ext) { return t }
        }
        return available.first { !sourceExts.contains($0.ext) } ?? available.first
    }
}

// MARK: - Per-target options

extension Target {
    var isLossyAudio: Bool { ["mp3", "m4a", "he-aac", "opus", "ogg", "wma", "ac3", "mp2"].contains(id) }
    var isLosslessAudio: Bool { ["wav", "aiff", "flac", "alac", "wv"].contains(id) }
    var isLossyImage: Bool { ["jpg", "heic", "avif", "webp"].contains(id) }
    var hasHardwareOption: Bool { ["mp4-h264", "mp4-hevc", "mov-prores", "mkv"].contains(id) }

    var bitrateOptions: [Int] {
        switch id {
        case "mp3": [0, 320, 256, 192, 160, 128, 96, 64]
        case "m4a": [320, 256, 192, 160, 128, 96]
        case "he-aac": [96, 80, 64, 48, 32]
        case "opus": [256, 192, 160, 128, 96, 64, 48, 32]
        case "ogg": [320, 256, 192, 160, 128, 96]
        case "wma": [256, 192, 160, 128, 96]
        case "ac3": [640, 448, 384, 256, 192]
        case "mp2": [384, 320, 256, 192, 128]
        default: []
        }
    }

    var defaultBitrate: Int {
        switch id {
        case "m4a": 256
        case "he-aac": 64
        case "opus": 160
        case "ogg", "wma": 192
        case "ac3": 448
        case "mp2": 256
        default: 0
        }
    }

    var sampleRates: [Int] {
        if id == "opus" { return [] }
        return isLossyAudio ? [0, 44100, 48000] : [0, 44100, 48000, 88200, 96000]
    }

    var hasChannelOption: Bool { id != "ogg" }

    /// PDF → a text format: the words and their fonts, without pictures or page layout.
    var isPDFText: Bool { ["pdf-txt", "pdf-docx", "pdf-odt", "pdf-rtf"].contains(id) }

    /// Whether the panel has anything to show under "Advanced" for this format.
    var hasSettings: Bool { !(group == .document && id != "pdf-doc") && !isPDFText && group != .font }
}

struct ConvSettings: Codable, Equatable {
    // Audio
    var audioBitrate = 0  // kbps; 0 = MP3 VBR best
    var sampleRate = 0  // 0 = same as source
    var channels = 0  // 0 = same, 1 = mono, 2 = stereo
    var bitDepth = 0  // 0 = auto (match source), 16, 24
    // Video
    var videoQuality = 0.65  // 0 = smallest … 1 = best
    var videoHeight = 0  // 0 = same as source
    var fps = 0  // 0 = same as source
    var keepAudio = true
    var hardware = true
    var gifWidth = 480
    var gifFps = 15
    // Image
    var imageQuality = 0.85
    var maxSize = 0  // longest edge in px; 0 = same as source
    // Documents / PDF
    var paperA4 = true
    var pdfDPI = 150

    init() {}

    /// Settings are saved per format as JSON. A key that's missing keeps its default, so settings
    /// saved by an older version survive an update that adds a field; unknown keys are ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, into value: inout T) throws {
            if let saved = try c.decodeIfPresent(T.self, forKey: key) { value = saved }
        }
        try read(.audioBitrate, into: &audioBitrate)
        try read(.sampleRate, into: &sampleRate)
        try read(.channels, into: &channels)
        try read(.bitDepth, into: &bitDepth)
        try read(.videoQuality, into: &videoQuality)
        try read(.videoHeight, into: &videoHeight)
        try read(.fps, into: &fps)
        try read(.keepAudio, into: &keepAudio)
        try read(.hardware, into: &hardware)
        try read(.gifWidth, into: &gifWidth)
        try read(.gifFps, into: &gifFps)
        try read(.imageQuality, into: &imageQuality)
        try read(.maxSize, into: &maxSize)
        try read(.paperA4, into: &paperA4)
        try read(.pdfDPI, into: &pdfDPI)
    }
}
