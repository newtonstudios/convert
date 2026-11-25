"""What kind of file something is, and what it really is inside.

Mirrors ``Sources/Convert/MediaKinds.swift`` and ``Sniff.swift``: the extension
decides the kind, and the first bytes are only consulted when the name can't be
trusted (``.ts`` is both TypeScript and an MPEG transport stream, and files get
renamed to the wrong extension all the time).
"""

from __future__ import annotations

import re

AUDIO = "audio"
VIDEO = "video"
IMAGE = "image"
PDF = "pdf"
DOCUMENT = "document"
FONT = "font"

# The extensions the Mac app accepts, per kind. Keep in step with MediaKinds.swift.
EXTENSIONS = {
    # M4A, ALAC, Opus, WMA, WavPack, DSF, ...
    AUDIO: [
        "mp3", "wav", "wave", "aif", "aiff", "aifc", "flac", "m4a", "m4b", "aac",
        "alac", "ogg", "oga", "opus", "wma", "mka", "ape", "wv", "tta", "dsf",
        "dff", "ac3", "eac3", "dts", "amr", "mp2", "caf", "weba",
    ],
    VIDEO: [
        "mp4", "m4v", "mov", "qt", "mkv", "webm", "avi", "flv", "wmv", "asf",
        "ts", "mts", "m2ts", "3gp", "3g2", "ogv", "mxf", "vob", "mpg", "mpeg",
        "m2v", "divx", "f4v",
    ],
    IMAGE: [
        "jpg", "jpeg", "jpe", "jfif", "png", "gif", "bmp", "dib", "tif", "tiff",
        "webp", "heic", "heif", "hif", "avif", "ico", "jxl", "psd", "tga", "dng",
        "cr2", "cr3", "nef", "nrw", "arw", "orf", "rw2", "raf", "pef", "srw",
        "erf", "3fr", "svg",
    ],
    PDF: ["pdf"],
    DOCUMENT: ["docx", "doc", "odt", "rtf", "txt", "text", "md", "markdown", "html", "htm"],
    FONT: ["ttf", "otf", "ttc", "otc", "woff", "woff2"],
}

BY_EXTENSION = {ext: kind for kind, exts in EXTENSIONS.items() for ext in exts}

# Selection rules, mirroring OutGroups.For: a video can also become audio, so
# video and audio files convert together and everything else goes in its own batch.
GROUPS_FOR_KIND = {
    AUDIO: {"audio"},
    VIDEO: {"video", "audio"},
    IMAGE: {"image"},
    PDF: {"pdf"},
    DOCUMENT: {"document"},
    FONT: {"font"},
}


def of(path):
    """The kind of a file by its name, or None when the extension is not one of ours."""
    ext = path.rsplit("/", 1)[-1]
    if "." not in ext:
        return None
    return BY_EXTENSION.get(ext.rsplit(".", 1)[-1].lower())


def compatible(kinds):
    """Whether these files may be converted together in one batch."""
    kinds = set(kinds)
    return len(kinds) == 1 or kinds == {AUDIO, VIDEO}


# ── What the contents say ────────────────────────────────────────────────


_IMAGE = {IMAGE}
_AUDIO = {AUDIO}
_VIDEO = {VIDEO}
_AUDIO_VIDEO = {AUDIO, VIDEO}
_FONT = {FONT}
_DOCUMENT = {DOCUMENT}


class Format:
    """A format these bytes belong to.

    ``name`` reads after "its contents are …", ``ext`` is the extension such a
    file usually carries, and ``kinds`` is what it can be converted as: an MP4
    can hold only audio, and a PDF can be behind an image name.
    """

    def __init__(self, name, ext, kinds):
        self.name = name
        self.ext = ext
        self.kinds = kinds


def _at(d, offset, *magic):
    return len(d) >= offset + len(magic) and d[offset:offset + len(magic)] == bytes(magic)


def _text(d, offset, text):
    return _at(d, offset, *text.encode("ascii"))


def _zero(d, start, end):
    return all(b == 0 for b in d[start:end + 1])


def is_transport_stream(d):
    """A sync byte (0x47) every 188 bytes; M2TS prefixes 4, some broadcasts add 16 for error correction."""
    for first, size in ((0, 188), (4, 192), (0, 204)):
        syncs = 0
        good = True
        for i in range(first, len(d), size):
            if d[i] != 0x47:
                good = False
                break
            syncs += 1
            if syncs >= 4:
                break
        if good and syncs >= 2:
            return True
    return False


def looks_like_text(d):
    """Text has no control bytes apart from whitespace (and escape, for coloured logs)."""
    if d.startswith(b"\xff\xfe") or d.startswith(b"\xfe\xff"):
        return True
    for c in d:
        if c < 0x09 or 0x0E <= c <= 0x1A or 0x1C <= c <= 0x1F:
            return False
    return True


def format_of(d):
    """The well-known format these first bytes belong to, or None when it is not one."""
    head = d[:64]
    text = lambda o, s: _text(d, o, s)

    if _at(head, 0, 0xFF, 0xD8, 0xFF):
        return Format("a JPEG image", "jpg", _IMAGE)
    if _at(head, 0, 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A):
        return Format("a PNG image", "png", _IMAGE)
    if text(0, "GIF87a") or text(0, "GIF89a"):
        return Format("a GIF image", "gif", _IMAGE)
    # Also most camera raw files.
    if _at(head, 0, 0x49, 0x49, 0x2A, 0x00) or _at(head, 0, 0x4D, 0x4D, 0x00, 0x2A):
        return Format("a TIFF image", "tiff", _IMAGE)
    if (text(0, "BM") and len(head) >= 18 and _zero(head, 6, 9)
            and head[14] in (12, 40, 52, 56, 108, 124) and _zero(head, 15, 17)):
        return Format("a BMP image", "bmp", _IMAGE)

    if text(0, "RIFF") or text(0, "RF64"):
        if text(8, "WAVE"):
            return Format("WAV audio", "wav", _AUDIO)
        if text(8, "AVI "):
            return Format("an AVI video", "avi", _VIDEO)
        if text(8, "WEBP"):
            return Format("a WebP image", "webp", _IMAGE)
    if text(0, "FORM") and (text(8, "AIFF") or text(8, "AIFC")):
        return Format("AIFF audio", "aiff", _AUDIO)

    # The MP4 family: the brand says what is inside. Unknown brands (camera raw,
    # …) are left to the converters rather than guessed at.
    if len(head) >= 12 and text(4, "ftyp"):
        brand = head[8:12].decode("latin-1")
        if brand in ("heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs", "mif1", "msf1"):
            return Format("a HEIC image", "heic", _IMAGE)
        if brand in ("avif", "avis"):
            return Format("an AVIF image", "avif", _IMAGE)
        if brand == "qt  ":
            return Format("a QuickTime movie", "mov", _AUDIO_VIDEO)
        if brand.startswith("M4A") or brand.startswith("M4B"):
            return Format("M4A audio", "m4a", _AUDIO_VIDEO)
        if (brand in ("isom", "mp41", "mp42", "avc1", "M4V ", "f4v ", "dash", "mmp4",
                      "MSNV", "av01")
                or brand.startswith(("iso", "3gp", "3g2"))):
            return Format("an MP4 video", "mp4", _AUDIO_VIDEO)
        return None
    if text(4, "moov") or text(4, "mdat") or text(4, "wide"):
        return Format("a QuickTime movie", "mov", _AUDIO_VIDEO)

    if text(0, "fLaC"):
        return Format("FLAC audio", "flac", _AUDIO)
    if text(0, "ID3") and len(head) >= 4 and 2 <= head[3] <= 4:
        return Format("MP3 audio", "mp3", _AUDIO)
    if text(0, "wvpk"):
        return Format("WavPack audio", "wv", _AUDIO)
    # An MPEG audio frame (MP3, or AAC in ADTS): 11 sync bits, then a valid
    # bitrate and sample rate.
    if (len(head) >= 3 and head[0] == 0xFF and (head[1] & 0xE0) == 0xE0 and head[1] < 0xFE
            and (head[2] & 0xF0) != 0xF0 and (head[2] & 0x0C) != 0x0C):
        return Format("MPEG audio (MP3 or AAC)", None, _AUDIO)

    if text(0, "OggS"):
        return Format("an Ogg file", "ogg", _AUDIO_VIDEO)
    if _at(head, 0, 0x1A, 0x45, 0xDF, 0xA3):
        return Format("a Matroska or WebM file", "mkv", _AUDIO_VIDEO)
    if _at(head, 0, 0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11):
        return Format("a Windows Media file", "wmv", _AUDIO_VIDEO)
    if _at(head, 0, 0x46, 0x4C, 0x56, 0x01):
        return Format("a Flash video", "flv", _VIDEO)
    if _at(head, 0, 0x00, 0x00, 0x01, 0xBA) or _at(head, 0, 0x00, 0x00, 0x01, 0xB3):
        return Format("an MPEG video", "mpg", _VIDEO)
    if is_transport_stream(d):
        return Format("an MPEG transport stream", "ts", _VIDEO)

    if text(0, "wOF2"):
        return Format("a WOFF2 font", "woff2", _FONT)
    if text(0, "wOFF"):
        return Format("a WOFF font", "woff", _FONT)
    if text(0, "OTTO"):
        return Format("an OpenType font", "otf", _FONT)
    if text(0, "ttcf"):
        return Format("a font collection", "ttc", _FONT)
    # A plain TrueType file starts with a version number, so its table count has
    # to add up too.
    if (_at(head, 0, 0x00, 0x01, 0x00, 0x00) or text(0, "true")) and len(head) >= 12:
        tables = head[4] << 8 | head[5]
        search_range = head[6] << 8 | head[7]
        if 0 < tables < 256 and search_range == 16 << (tables.bit_length() - 1):
            return Format("a TrueType font", "ttf", _FONT)

    # A PDF can also be behind an image name (Illustrator files), so it passes
    # for both.
    if text(0, "%PDF-"):
        return Format("a PDF", "pdf", {PDF, IMAGE})
    if text(0, "{\\rtf"):
        return Format("a Rich Text document", "rtf", _DOCUMENT)
    if _at(head, 0, 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1):
        return Format("an old Microsoft Office document", None, {DOCUMENT, IMAGE})
    if _at(head, 0, 0x50, 0x4B, 0x03, 0x04):
        return Format("a ZIP archive or Office document", None, _DOCUMENT)
    if is_svg(d):
        return Format("an SVG image", "svg", _IMAGE)
    return None


_SVG_ELEMENT = re.compile(rb"<svg[\s>]")
_HTML_ELEMENT = re.compile(rb"<html[\s>]", re.I)


def is_svg(d):
    """An SVG: XML text whose first element, within the first bytes, is <svg>."""
    text = d[:HEADER_LENGTH]
    if text.startswith(b"\xef\xbb\xbf"):
        text = text[3:]
    text = text.lstrip()
    if text.startswith(b"<svg"):
        return True
    if text[:9].lower() == b"<!doctype" and not text[:13].lower() == b"<!doctype svg":
        return False
    if not (text.startswith((b"<?xml", b"<!--")) or text[:9].lower() == b"<!doctype"):
        return False
    return _SVG_ELEMENT.search(text) is not None and _HTML_ELEMENT.search(text) is None


HEADER_LENGTH = 4096


def header(path):
    """The first bytes of a file, or None when it can't be read."""
    try:
        with open(path, "rb") as f:
            return f.read(HEADER_LENGTH)
    except OSError:
        return None


def verify(path, kind):
    """Raise when the contents clearly belong to a different kind than the name says.

    An audio file renamed to ``.jpg`` gets a sentence about that instead of a
    decoder's error.
    """
    from .errors import ConvertError

    head = header(path)
    if head is None:
        return
    actual = format_of(head)
    if actual is None:
        # Nothing recognisable. Text is recognisable enough to mention when the
        # name promises audio, video, an image or a font.
        if kind != DOCUMENT and looks_like_text(head):
            raise ConvertError(_mismatch(path, "plain text", None))
        return
    if kind in actual.kinds:
        return
    # Text may start with anything, including another format's magic letters.
    if kind == DOCUMENT and looks_like_text(head):
        return
    raise ConvertError(_mismatch(path, actual.name, actual.ext))


def _mismatch(path, description, wanted_ext):
    """The sentence for a file whose contents don't match its name."""
    name = path.rsplit("/", 1)[-1]
    ext = "" if "." not in name else "." + name.rsplit(".", 1)[-1].lower()
    message = "This isn't really a %s file: its contents are %s." % (ext, description)
    if wanted_ext:
        message += " Rename it to .%s and convert it again." % wanted_ext
    return message


def kind_of(path):
    """The kind to convert this as, looking inside only where the name is ambiguous."""
    if path.lower().endswith(".ts"):
        head = header(path)
        if head and not is_transport_stream(head) and looks_like_text(head):
            return DOCUMENT
    return of(path)
