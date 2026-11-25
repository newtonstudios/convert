"""Fonts, through fontTools.

The Mac uses CoreText, the Windows port uses a font library; the web formats
here are WOFF and WOFF2, and the desktop format is the plain TTF/OTF a system
font folder wants.

A collection (``.ttc``/``.otc``) holds several fonts in one file, so -- as on
the Mac -- it becomes a folder with one file per font rather than silently
keeping only the first.
"""

from __future__ import annotations

import os

from . import paths, tools
from .errors import ConvertError

WEB = {"font-woff2": ("woff2", "WOFF2"), "font-woff": ("woff", "WOFF")}


def convert(input_path, target, settings, runner, progress):
    have, brotli_ok = tools.fonttools()
    if not have:
        raise ConvertError("fontTools isn't installed, and it is what converts fonts. "
                           "Install it with: python3 -m pip install --user fonttools brotli")
    if target.id == "font-woff2" and not brotli_ok:
        raise ConvertError("WOFF2 needs Brotli, which fontTools doesn't have here. "
                           "Install it with: python3 -m pip install --user brotli")

    from fontTools.ttLib import TTCollection, TTFont

    work = paths.temp_dir()
    try:
        try:
            collection = TTCollection(input_path, lazy=False)
            fonts = list(collection.fonts)
            collection.close()
        except Exception:
            fonts = [TTFont(input_path, lazy=False)]

        # A collection is what it is; anything else is one font.
        if len(fonts) == 1:
            font = fonts[0]
            ext = _save(font, target, work, "output")
            runner.check()
            dest = paths.unique_output(input_path, ext)
            paths.move_into_place(os.path.join(work, "output." + ext), dest)
            progress(1.0)
            return [dest]

        folder = paths.unique_folder(input_path, " fonts")
        try:
            os.makedirs(folder)
        except OSError as e:
            raise ConvertError("Couldn't create %s: %s" % (os.path.basename(folder), e.strerror or e))
        written = []
        try:
            for number, font in enumerate(fonts, start=1):
                runner.check()
                name = font["name"].getDebugName(4) or ("font %d" % number)
                safe = _safe_name(name)
                ext = _save(font, target, work, "font-%d" % number)
                dest = os.path.join(folder, "%s.%s" % (safe, ext))
                paths.move_into_place(os.path.join(work, "font-%d.%s" % (number, ext)), dest)
                written.append(dest)
                progress(number / len(fonts))
            progress(1.0)
            return [folder]
        except ConvertError:
            paths.try_delete(folder)
            raise
    except ConvertError:
        raise
    except Exception as e:
        raise ConvertError("Couldn't read this font: %s" % e)
    finally:
        paths.try_delete(work)


def _save(font, target, work, name):
    """Write one font in the target's format and return the extension it got."""
    if target.id in WEB:
        flavor, description = WEB[target.id]
        try:
            font.flavor = flavor
            path = os.path.join(work, name + "." + flavor)
            font.save(path)
        except Exception as e:
            raise ConvertError("Couldn't write a %s font: %s" % (description, e))
        return flavor

    # Desktop: back to a plain font. A WOFF or WOFF2 source carries the
    # original outline flavour, so the extension follows it rather than the
    # format it arrived in.
    ext = "otf" if getattr(font, "sfntVersion", "\x00\x01\x00\x00") == "OTTO" else "ttf"
    try:
        font.flavor = None
        path = os.path.join(work, name + "." + ext)
        font.save(path)
    except Exception as e:
        raise ConvertError("Couldn't write a desktop font: %s" % e)
    return ext


def _safe_name(name):
    """A font's full name as a file name."""
    cleaned = "".join(c if c not in '/\\:*?"<>|' and ord(c) >= 32 else " " for c in name)
    cleaned = " ".join(cleaned.split()).strip(". ")
    return cleaned or "font"
