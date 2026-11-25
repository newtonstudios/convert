"""Every format Convert offers, and the settings one conversion runs with.

The target IDs, labels, order, defaults and option ranges come from
``Sources/Convert/Formats.swift`` -- they are what the Mac app and the Windows
port both use, and a conversion named ``mp3`` means the same thing on all
three.

What differs is availability. The Mac formats depend on macOS; here they
depend on what is installed, and a format that can't be produced is *hidden*
rather than offered and then failing:

======================  ==================================================
audio, video            ``ffmpeg``, and the encoder for that format
images                  ImageMagick, plus its delegate for HEIC/AVIF/PDF
documents -> PDF        LibreOffice, or a Chromium-family browser for
                        Markdown, plain text and HTML
PDF -> pages            ``pdftoppm`` (poppler-utils)
PDF -> text/Word        ``pdftotext``, with Convert writing the document
fonts                   ``fontTools`` (and Brotli for WOFF2)
======================  ==================================================
"""

from __future__ import annotations

import json
import os

from . import kinds, tools

VIDEO = "video"
AUDIO = "audio"
IMAGE = "image"
DOCUMENT = "document"
PDF_PAGES = "pdf"
FONT = "font"

GROUP_LABELS = {VIDEO: "Video", AUDIO: "Audio", IMAGE: "Image",
                DOCUMENT: "Document", PDF_PAGES: "From PDF", FONT: "Font"}


class Target:
    def __init__(self, id, label, ext, group):
        self.id = id
        self.label = label
        self.ext = ext
        self.group = group

    def __repr__(self):
        return "Target(%s)" % self.id

    # ── The options this format has, from Formats.swift ──────────────────

    @property
    def bitrate_options(self):
        return {
            "mp3": [0, 320, 256, 192, 160, 128, 96, 64],
            "m4a": [320, 256, 192, 160, 128, 96],
            "he-aac": [96, 80, 64, 48, 32],
            "opus": [256, 192, 160, 128, 96, 64, 48, 32],
            "ogg": [320, 256, 192, 160, 128, 96],
            "wma": [256, 192, 160, 128, 96],
            "ac3": [640, 448, 384, 256, 192],
            "mp2": [384, 320, 256, 192, 128],
        }.get(self.id, [])

    @property
    def default_bitrate(self):
        return {"m4a": 256, "he-aac": 64, "opus": 160, "ogg": 192, "wma": 192,
                "ac3": 448, "mp2": 256}.get(self.id, 0)

    @property
    def is_lossy_audio(self):
        return self.id in ("mp3", "m4a", "he-aac", "opus", "ogg", "wma", "ac3", "mp2")

    @property
    def is_lossless_audio(self):
        return self.id in ("wav", "aiff", "flac", "alac", "wv")

    @property
    def sample_rates(self):
        if self.id == "opus":
            return [0]
        return [0, 44100, 48000] if self.is_lossy_audio else [0, 44100, 48000, 88200, 96000]

    @property
    def has_channel_option(self):
        return self.id != "ogg"

    @property
    def has_hardware_option(self):
        # ProRes and AV1 have no usable hardware encoder here, so they don't
        # offer the switch at all rather than offering one that does nothing.
        return self.id in ("mp4-h264", "mp4-hevc", "mkv")

    @property
    def is_pdf_text(self):
        return self.id in ("pdf-txt", "pdf-docx", "pdf-odt", "pdf-rtf")


CATALOGUE = [
    Target("mp4-h264", "MP4 (H.264)", "mp4", VIDEO),
    Target("mp4-hevc", "MP4 (HEVC / H.265)", "mp4", VIDEO),
    Target("mov-prores", "MOV (ProRes 422)", "mov", VIDEO),
    Target("webm", "WebM (VP9)", "webm", VIDEO),
    Target("mkv", "MKV (H.264)", "mkv", VIDEO),
    Target("mp4-av1", "MP4 (AV1)", "mp4", VIDEO),
    Target("gif", "GIF (animated)", "gif", VIDEO),

    Target("mp3", "MP3", "mp3", AUDIO),
    Target("m4a", "M4A (AAC)", "m4a", AUDIO),
    Target("he-aac", "M4A (HE-AAC, small)", "m4a", AUDIO),
    Target("wav", "WAV", "wav", AUDIO),
    Target("aiff", "AIFF", "aiff", AUDIO),
    Target("flac", "FLAC", "flac", AUDIO),
    Target("alac", "ALAC (Apple Lossless)", "m4a", AUDIO),
    Target("opus", "Opus", "opus", AUDIO),
    Target("ogg", "OGG (Vorbis)", "ogg", AUDIO),
    Target("wma", "WMA", "wma", AUDIO),
    Target("ac3", "AC3 (Dolby Digital)", "ac3", AUDIO),
    Target("wv", "WavPack", "wv", AUDIO),
    Target("mp2", "MP2", "mp2", AUDIO),

    Target("jpg", "JPEG", "jpg", IMAGE),
    Target("png", "PNG", "png", IMAGE),
    Target("heic", "HEIC", "heic", IMAGE),
    Target("avif", "AVIF", "avif", IMAGE),
    Target("webp", "WebP", "webp", IMAGE),
    Target("tiff", "TIFF", "tiff", IMAGE),
    Target("gif-img", "GIF", "gif", IMAGE),
    Target("bmp", "BMP", "bmp", IMAGE),
    Target("pdf-img", "PDF", "pdf", IMAGE),

    Target("pdf-doc", "PDF", "pdf", DOCUMENT),
    Target("docx", "Word (DOCX)", "docx", DOCUMENT),
    Target("doc", "Word 97\u20132003 (DOC)", "doc", DOCUMENT),
    Target("odt", "OpenDocument (ODT)", "odt", DOCUMENT),
    Target("rtf", "Rich Text (RTF)", "rtf", DOCUMENT),
    Target("txt", "Plain Text", "txt", DOCUMENT),
    Target("html", "HTML", "html", DOCUMENT),

    Target("pdf-png", "PNG (one per page)", "png", PDF_PAGES),
    Target("pdf-jpg", "JPEG (one per page)", "jpg", PDF_PAGES),
    Target("pdf-docx", "Word (DOCX, text only)", "docx", PDF_PAGES),
    Target("pdf-odt", "OpenDocument (ODT, text only)", "odt", PDF_PAGES),
    Target("pdf-rtf", "Rich Text (RTF, text only)", "rtf", PDF_PAGES),
    Target("pdf-txt", "Plain Text", "txt", PDF_PAGES),

    Target("font-woff2", "WOFF2 (web font)", "woff2", FONT),
    Target("font-woff", "WOFF (web font)", "woff", FONT),
    Target("font-desktop", "TTF / OTF (desktop font)", "ttf", FONT),
]

BY_ID = {t.id: t for t in CATALOGUE}

# The encoder each media format needs. None means ffmpeg always has it.
NEEDS_ENCODER = {
    "mp3": "libmp3lame",
    "m4a": None,
    "he-aac": "libfdk_aac",
    "opus": "libopus",
    "ogg": None,
    "wma": "wmav2",
    "ac3": "ac3",
    "mp2": "mp2",
    "wav": None,
    "aiff": None,
    "flac": "flac",
    "alac": "alac",
    "wv": "wavpack",
    "mp4-h264": "libx264",
    "mp4-hevc": "libx265",
    "mov-prores": "prores_ks",
    "webm": "libvpx-vp9",
    "mkv": "libx264",
    "mp4-av1": "libsvtav1",
    "gif": None,
}

# Image targets ImageMagick may or may not be able to write here (a delegate or
# a policy decides): asked by writing one, see tools.magick_writes.
IMAGE_NEEDS_PROBE = {"heic", "avif", "webp", "pdf-img"}

WEBP_WRITE = "webp"


def available(target, source_kind=None, source_ext=None):
    """Whether this format can be produced right now, for this kind of input.

    With no source given (the "everything, and whether it's available" list)
    the question is only whether any way to write it exists, not whether it
    applies to one particular file.
    """
    generic = source_ext is None
    g = target.group
    if g in (AUDIO, VIDEO):
        if not tools.has("ffmpeg"):
            return False
        needed = NEEDS_ENCODER.get(target.id)
        if needed and not tools.has_encoder(needed):
            return False
        if target.id == "ogg" and not (tools.has_encoder("libvorbis") or tools.has_encoder("vorbis")):
            return False
        return True

    if g == IMAGE:
        # SVG is drawn by rsvg-convert, never by ImageMagick (see images.py).
        if (source_ext or "").lower() == "svg" and not tools.has("rsvg-convert"):
            return False
        if target.id == WEBP_WRITE and tools.find("cwebp") and not tools.magick():
            return True  # cwebp alone is enough for WebP
        if not tools.magick():
            return False
        if target.id in IMAGE_NEEDS_PROBE:
            return tools.magick_writes(target.ext)
        return True

    if g == DOCUMENT:
        ext = (source_ext or "").lower()
        if target.id == "pdf-doc":
            if generic:
                return tools.has("soffice") or tools.has("chrome")
            by_office = _needs_office(ext) and tools.has("soffice")
            by_browser = _needs_browser(ext) and tools.has("chrome")
            return by_office or by_browser
        if target.id in ("docx", "odt", "rtf", "doc"):
            # Markdown and plain text reach these through an HTML step, which
            # LibreOffice reads; without it there is nothing to write them with.
            return tools.has("soffice")
        if target.id in ("html", "txt"):
            # Markdown and text are rendered by Convert itself; anything else
            # has to go through LibreOffice.
            if generic or ext in ("md", "markdown", "txt", "text"):
                return True
            return tools.has("soffice")
        return False

    if g == PDF_PAGES:
        if target.id in ("pdf-png", "pdf-jpg"):
            reachable = generic or source_kind == kinds.PDF
            return tools.has("pdftoppm") and reachable
        reachable = generic or source_kind == kinds.PDF
        return tools.has("pdftotext") and reachable

    if g == FONT:
        have, brotli_ok = tools.fonttools()
        if not have:
            return False
        if target.id == "font-woff2" and not brotli_ok:
            return False
        return True

    return False


def _needs_office(ext):
    return ext in ("doc", "docx", "odt", "rtf")


def _needs_browser(ext):
    return ext in ("md", "markdown", "txt", "text", "html", "htm")


def groups_for(kind):
    return kinds.GROUPS_FOR_KIND.get(kind, set())


def offered_for(path):
    """Every format this particular file can be converted to right now."""
    kind = kinds.kind_of(path)
    if kind is None:
        return []
    ext = path.rsplit(".", 1)[-1].lower() if "." in path.rsplit("/", 1)[-1] else ""
    allowed = groups_for(kind)
    return [t for t in CATALOGUE if t.group in allowed and available(t, kind, ext)]


def grouped(targets):
    """Targets in display order, one list per group."""
    out = []
    for group in (VIDEO, AUDIO, IMAGE, DOCUMENT, PDF_PAGES, FONT):
        members = [t for t in targets if t.group == group]
        if members:
            out.append((group, members))
    return out


def common_targets(paths):
    """The formats offered for a whole selection: what every file can become.

    A batch is one choice for all of them, so an option that one file can't
    produce would fail halfway through.
    """
    sets = [set(t.id for t in offered_for(p)) for p in paths]
    if not sets:
        return []
    shared = set.intersection(*sets)
    return [t for t in CATALOGUE if t.id in shared]


def preferred(paths, targets):
    """A sensible first choice, skipping the format the files are already in."""
    exts = set(p.rsplit(".", 1)[-1].lower() for p in paths if "." in p)
    kind = kinds.kind_of(paths[0]) if paths else None
    order = {
        kinds.AUDIO: ["mp3", "wav", "m4a"],
        kinds.VIDEO: ["mp4-h264", "mov-prores"],
        kinds.IMAGE: ["jpg", "png"],
        kinds.PDF: ["pdf-png"],
        kinds.DOCUMENT: ["pdf-doc", "docx"],
        kinds.FONT: ["font-woff2", "font-desktop"],
    }.get(kind, [])
    for id in order:
        for t in targets:
            if t.id == id and t.ext not in exts:
                return t
    for t in targets:
        if t.ext not in exts:
            return t
    return targets[0] if targets else None


# ── Settings ─────────────────────────────────────────────────────────────


class Settings:
    """The settings of one conversion, under the Mac's names.

    A missing key keeps its default, so settings saved by an older version
    survive an update that adds a field; a name that isn't a setting is an
    error, because a typo should not quietly convert with the defaults.
    """

    FIELDS = {
        "audioBitrate": 0,      # kbps; 0 = MP3 VBR best
        "sampleRate": 0,        # 0 = same as source
        "channels": 0,          # 0 = same, 1 = mono, 2 = stereo
        "bitDepth": 0,          # 0 = match source, 16, 24
        "videoQuality": 0.65,   # 0 = smallest, 1 = best
        "videoHeight": 0,       # 0 = same as source
        "fps": 0,
        "keepAudio": True,
        "hardware": True,
        "gifWidth": 480,
        "gifFps": 15,
        "imageQuality": 0.85,
        "maxSize": 0,           # longest edge in px; 0 = same as source
        "paperA4": True,
        "pdfDPI": 150,
    }

    def __init__(self, **values):
        for name, default in self.FIELDS.items():
            setattr(self, name, values.get(name, default))

    def replace(self, **values):
        merged = dict(self.__dict__)
        merged.update(values)
        return Settings(**merged)

    def to_json(self):
        return json.dumps({k: getattr(self, k) for k in self.FIELDS}, indent=2)

    @classmethod
    def from_json(cls, text):
        if not text or not text.strip():
            return cls()
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            raise ValueError("expected a JSON object such as {\"hardware\": false}")
        if not isinstance(data, dict):
            raise ValueError("expected a JSON object such as {\"hardware\": false}")
        unknown = sorted(set(data) - set(cls.FIELDS))
        if unknown:
            raise ValueError("unknown setting %s; known: %s"
                             % (", ".join('"%s"' % u for u in unknown),
                                ", ".join(sorted(cls.FIELDS))))
        return cls(**data)

    @classmethod
    def from_environment(cls):
        return cls.from_json(os.environ.get("CONVERT_SETTINGS", ""))
