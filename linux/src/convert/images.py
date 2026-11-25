"""Images, through ImageMagick (``magick`` on 7, ``convert`` on 6).

The Mac uses ImageIO and the Windows port uses Magick.NET; here the policy is
the same in spirit:

* a file is copied into a plain-name temp file first, because ImageMagick gives
  meaning to parts of a name (``photo[1].jpg``, ``%d``) and a name is just a
  name;
* ImageMagick is told which decoder to use (``PNG:input.png``) instead of being
  left to guess from the contents, so a file can't steer it into a coder that
  draws or fetches what the file says (MVG, MSL, SVG, text, URLs, PostScript);
* every call runs under Convert's own ImageMagick policy, read after the
  system's (``tools.magick_env``, ``magick/ImageMagick/policy.xml``);
* SVG never reaches ImageMagick: it is checked to refer to nothing outside
  itself, then drawn by ``rsvg-convert`` in a folder of its own, and the
  picture that comes out is converted like any PNG;
* every conversion runs under memory, map and disk ceilings, so a small file
  claiming to be an enormous picture is refused instead of eating the machine;
* HEIC, AVIF, WebP and PDF are only offered when this ImageMagick can really
  write them -- asked by writing one, see ``tools.magick_writes``.
"""

from __future__ import annotations

import os
import re
import shutil

from . import kinds, paths, tools
from .errors import ConvertError

# A photo's EXIF is part of the photo; a converted file keeps it. What is
# dropped is the Colour Management Profile only where the target can't hold it
# -- ImageMagick handles that itself by coder.

CEILINGS = ["-limit", "memory", "512MiB", "-limit", "map", "1GiB", "-limit", "disk", "2GiB"]

EXT_WEBP = "webp"

# Camera raw files, all read by ImageMagick's DNG coder (libraw, or dcraw).
RAW = ("dng", "cr2", "cr3", "nef", "nrw", "arw", "orf", "rw2", "raf", "pef", "srw", "erf", "3fr")

# The decoder for each image extension Convert accepts (kinds.EXTENSIONS),
# as ImageMagick 6 and 7 both name it. SVG is missing on purpose.
DECODER = {
    "jpg": "JPEG", "jpeg": "JPEG", "jpe": "JPEG", "jfif": "JPEG",
    "png": "PNG", "gif": "GIF", "bmp": "BMP", "dib": "DIB",
    "tif": "TIFF", "tiff": "TIFF", "webp": "WEBP",
    "heic": "HEIC", "heif": "HEIC", "hif": "HEIC", "avif": "AVIF",
    "ico": "ICO", "jxl": "JXL", "psd": "PSD", "tga": "TGA",
}
DECODER.update({ext: "DNG" for ext in RAW})

# What the contents say, when they say it (kinds.format_of), wins over the
# name: a JPEG saved as .png is still read as the JPEG it is.
_SNIFFED = {"jpg": "JPEG", "png": "PNG", "gif": "GIF", "bmp": "BMP", "webp": "WEBP",
            "heic": "HEIC", "avif": "AVIF", "tiff": "TIFF"}


def decoder_for(ext, head):
    """The ImageMagick decoder for a file with this extension and these first bytes.

    Returns ``"SVG"`` for an SVG (which goes to rsvg-convert, never to
    ImageMagick) and raises for anything Convert won't hand to ImageMagick.
    """
    ext = (ext or "").lower()
    sniffed = kinds.format_of(head or b"")
    if sniffed is not None and sniffed.ext == "svg":
        return "SVG"
    if sniffed is not None and sniffed.ext == "pdf":
        # Reading a PDF would run Ghostscript inside ImageMagick.
        raise ConvertError("This isn't really a .%s file: its contents are a PDF. "
                           "Rename it to .pdf and convert it again." % ext)
    if sniffed is not None and sniffed.ext in _SNIFFED:
        # Most camera raw files are TIFF inside; they still need the raw decoder.
        if sniffed.ext == "tiff" and ext in RAW:
            return "DNG"
        return _SNIFFED[sniffed.ext]
    if ext == "svg":
        raise ConvertError("This isn't really an SVG file")
    if ext in DECODER:
        return DECODER[ext]
    raise ConvertError("Convert doesn't read .%s images" % ext)


# ── SVG ──────────────────────────────────────────────────────────────────

# Anything in an SVG that could make a renderer read another file or reach the
# network. A self-contained SVG has none of these, apart from references inside
# itself ("#id") and pictures embedded as data.
_ATTR_URL = re.compile(r"""(?:^|[\s"'])((?:[\w.-]+:)?(?:href|src))\s*=\s*("|')(.*?)\2""", re.I | re.S)
_CSS_URL = re.compile(r"""url\(\s*(["']?)(.*?)\1\s*\)""", re.I | re.S)
_FORBIDDEN = [
    (re.compile(r"<!ENTITY", re.I), "an entity declaration"),
    (re.compile(r"<\?xml-stylesheet", re.I), "an external stylesheet"),
    (re.compile(r"@import", re.I), "a stylesheet import"),
    (re.compile(r"XInclude|<\s*[\w.-]*:?include\b", re.I), "an XInclude"),
]


def _local(value):
    value = value.strip()
    return value.startswith("#") or value.lower().startswith("data:")


def check_svg(data):
    """Raise unless this SVG refers to nothing outside itself.

    Deliberately strict: a value Convert can't be sure about (an entity, an
    escaped character at the start of a reference) is refused rather than
    trusted to the renderer.
    """
    if b"\x00" in data or data[:2] == b"\x1f\x8b":
        raise ConvertError("Convert only converts plain-text SVG files")
    text = data.decode("utf-8", errors="replace")
    for pattern, what in _FORBIDDEN:
        if pattern.search(text):
            raise ConvertError("This SVG contains %s, which can read other files, "
                               "so Convert won't open it" % what)
    for match in _ATTR_URL.finditer(text):
        if not _local(match.group(3)):
            raise ConvertError("This SVG links to \u201c%s\u201d, outside itself, so "
                               "Convert won't open it" % match.group(3)[:60])
    for match in _CSS_URL.finditer(text):
        if not _local(match.group(2)):
            raise ConvertError("This SVG links to \u201c%s\u201d, outside itself, so "
                               "Convert won't open it" % match.group(2)[:60])


def _render_svg(staged, work, runner):
    """Draw an SVG as a PNG with rsvg-convert, keeping its transparency."""
    rsvg = tools.find("rsvg-convert")
    if not rsvg:
        raise ConvertError("Converting SVG needs rsvg-convert. Install it with your package "
                           "manager (for example: sudo apt install librsvg2-bin)")
    with open(staged, "rb") as f:
        check_svg(f.read())
    # On its own in a folder: librsvg only ever loads files next to the SVG
    # or below it, and there is nothing there but the SVG.
    alone = os.path.join(work, "svg")
    os.mkdir(alone, 0o700)
    source = os.path.join(alone, "input.svg")
    os.replace(staged, source)
    out = os.path.join(work, "rendered.png")
    tools.run([rsvg, "-f", "png", "-o", out, source], runner=runner, timeout=120, check=True)
    if not os.path.exists(out) or os.path.getsize(out) == 0:
        raise ConvertError("Couldn't draw this SVG")
    return out


# ── Converting ───────────────────────────────────────────────────────────


def convert(input_path, target, settings, runner, progress):
    work = paths.temp_dir()
    try:
        source_ext = input_path.rsplit(".", 1)[-1].lower() if "." in os.path.basename(input_path) else "bin"
        staged = os.path.join(work, "input." + source_ext)
        try:
            shutil.copyfile(input_path, staged)
        except OSError as e:
            raise ConvertError("Couldn't read the file: %s" % (e.strerror or e))
        runner.check()

        # Decided from the copy, so what is checked is what gets converted.
        decoder = decoder_for(source_ext, kinds.header(staged))
        if decoder == "SVG":
            staged = _render_svg(staged, work, runner)
            decoder = "PNG"
        runner.check()

        out = os.path.join(work, "output." + target.ext)
        quality = int(round(max(0.0, min(1.0, settings.imageQuality)) * 100))

        if target.id == "webp" and tools.find("cwebp"):
            _cwebp(staged, decoder, out, quality, runner)
        else:
            _magick(staged, decoder, out, target, settings, quality)
        runner.check()

        if not os.path.exists(out) or os.path.getsize(out) == 0:
            raise ConvertError("Couldn't convert this image")

        dest = paths.unique_output(input_path, target.ext)
        paths.move_into_place(out, dest)
        progress(1.0)
        return [dest]
    finally:
        paths.try_delete(work)


def _cwebp(staged, decoder, out, quality, runner):
    """WebP through cwebp, which is the Mac's engine too.

    It only reads PNG, JPEG and TIFF, so a file it refuses (or anything else
    that got here) goes back to ImageMagick rather than failing.
    """
    try:
        tools.run([tools.find("cwebp"), "-quiet", "-q", str(quality), staged, "-o", out],
                  runner=runner, timeout=120, check=True)
    except ConvertError:
        if os.path.exists(out):
            paths.try_delete(out)
        image = tools.magick()
        if not image:
            raise
        args = [image] + CEILINGS + [_source(staged, decoder), "-quality", str(quality), out]
        tools.run(args, runner=runner, check=True, env=tools.magick_env())


def _source(staged, decoder, first_frame=True):
    """The input argument: the decoder named, and the first frame unless all are kept."""
    return "%s:%s%s" % (decoder, staged, "[0]" if first_frame else "")


def _magick(staged, decoder, out, target, settings, quality):
    image = tools.magick()
    if not image:
        raise ConvertError("ImageMagick isn't installed. Install it with your package "
                           "manager (for example: sudo apt install imagemagick)")
    args = [image] + CEILINGS

    # The first frame of an animated GIF or a multi-image HEIC, which is what
    # the Mac keeps too.
    args.append(_source(staged, decoder, first_frame=not _keeps_animation(target)))

    longest = int(settings.maxSize or 0)
    if longest > 0:
        # ">" means "only shrink": a small picture is never blown up into a
        # blurry big one.
        args += ["-resize", "%dx%d>" % (longest, longest)]

    if target.ext in ("jpg", "jpeg", "webp", "avif", "heic", "tiff", "pdf"):
        args += ["-quality", str(quality)]
    if target.ext == "png":
        # Keep the alpha channel, drop the heavy 16-bit depth a screenshot
        # doesn't need.
        args += ["-define", "png:compression-level=9"]
    if target.id == "pdf-img":
        # A PDF is a document, not a preview: no extra JPEG pass over it.
        args += ["-compress", "jpeg"]

    args.append(out)
    code, _, err = tools.run(args, runner=None, env=tools.magick_env())
    if code != 0 or not os.path.exists(out):
        raise ConvertError("Couldn't convert this image: %s"
                           % (tools.last_line(err) or "ImageMagick failed"))


def _keeps_animation(target):
    """A GIF stays a GIF: keeping every frame is the point of the format."""
    return target.id == "gif-img"
