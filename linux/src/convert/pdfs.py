"""PDFs, with Poppler, and the text-only document writers.

Mirrors ``PdfConv.cs``:

* **To PNG or JPEG** -- ``pdftoppm`` renders at the chosen DPI. One page becomes
  one file; several pages become a folder, ``Name pages/``, with ``page 1.png``,
  ``page 2.png`` and so on, because a pile of loose files next to somebody's
  PDF is worse than a folder.
* **To text** -- ``pdftotext`` reading in its natural order rather than its
  layout-preserving one, so a paragraph comes back as a paragraph instead of as
  the lines the page happened to break it into.
* **To Word, ODT or RTF** -- the same text, put into a document by Convert
  itself (``docwrite.py``). Text only is what the format says it is.
"""

from __future__ import annotations

import glob
import os
import re
import shutil

from . import docwrite, paths, tools
from .errors import ConvertError


def convert(input_path, target, settings, runner, progress):
    if not tools.has("pdftotext"):
        raise ConvertError("Poppler isn't installed. Install it with your package "
                           "manager (for example: sudo apt install poppler-utils)")
    work = paths.temp_dir()
    try:
        if target.id in ("pdf-png", "pdf-jpg"):
            return _pages(input_path, target, settings, work, runner, progress)
        text = _text(input_path, work, runner)
        runner.check()

        if target.id == "pdf-txt":
            dest = paths.unique_output(input_path, "txt")
            paths.write_new(dest, text.encode("utf-8"))
            progress(1.0)
            return [dest]

        paragraphs = docwrite.split_paragraphs(text)
        out = os.path.join(work, "output." + target.ext)
        if target.id == "pdf-docx":
            docwrite.write_docx(out, paragraphs)
        elif target.id == "pdf-odt":
            docwrite.write_odt(out, paragraphs)
        elif target.id == "pdf-rtf":
            docwrite.write_rtf(out, paragraphs)
        else:
            raise ConvertError("Unsupported target")

        runner.check()
        dest = paths.unique_output(input_path, target.ext)
        paths.move_into_place(out, dest)
        progress(1.0)
        return [dest]
    finally:
        paths.try_delete(work)


def _text(input_path, work, runner):
    try:
        code, out, err = tools.run([tools.find("pdftotext"), "-enc", "UTF-8", input_path, "-"],
                                   runner=runner)
    except ConvertError:
        raise
    if not out.strip() and code != 0:
        raise ConvertError("Couldn't read this PDF: %s"
                           % (tools.last_line(err) or "it may be damaged or password-protected"))
    if not out.strip():
        raise ConvertError("This PDF has no text: it is probably a scan. Convert it to "
                           "images instead, or run it through OCR first.")
    return out


def _pages(input_path, target, settings, work, runner, progress):
    if not tools.has("pdftoppm"):
        raise ConvertError("Rendering PDF pages needs poppler-utils "
                           "(for example: sudo apt install poppler-utils)")
    dpi = int(settings.pdfDPI or 150)
    dpi = max(36, min(600, dpi))
    quality = int(round(max(0.0, min(1.0, settings.imageQuality)) * 100))
    prefix = os.path.join(work, "page")
    args = [tools.find("pdftoppm"), "-r", str(dpi)]
    if target.id == "pdf-jpg":
        args += ["-jpeg", "-jpegopt", "quality=%d" % quality]
    else:
        args += ["-png"]
    args += [input_path, prefix]

    code, _, err = tools.run(args, runner=runner)
    produced = sorted(glob.glob(prefix + "-*." + target.ext),
                      key=lambda p: int(re.search(r"-(\d+)\.[a-z]+$", p).group(1))
                      if re.search(r"-(\d+)\.[a-z]+$", p) else 0)
    if not produced:
        raise ConvertError("Couldn't read this PDF: %s"
                           % (tools.last_line(err) or "it may be damaged or password-protected"))
    runner.check()

    if len(produced) == 1:
        dest = paths.unique_output(input_path, target.ext)
        paths.move_into_place(produced[0], dest)
        progress(1.0)
        return [dest]

    folder = paths.unique_folder(input_path, " pages")
    try:
        os.makedirs(folder)
    except OSError as e:
        raise ConvertError("Couldn't create %s: %s" % (os.path.basename(folder), e.strerror or e))

    written = []
    try:
        for number, source in enumerate(produced, start=1):
            runner.check()
            dest = os.path.join(folder, "page %d.%s" % (number, target.ext))
            paths.move_into_place(source, dest)
            written.append(dest)
            progress(number / len(produced))
    except ConvertError:
        # A half-filled folder of pages is not a conversion; remove it rather
        # than leave the user with a puzzle.
        paths.try_delete(folder)
        raise
    return [folder]


def page_count(path):
    """How many pages a PDF has, when poppler can say (used by the tests)."""
    pdfinfo = tools.find("pdfinfo")
    if not pdfinfo:
        return None
    try:
        _, out, _ = tools.run([pdfinfo, path], timeout=30)
    except ConvertError:
        return None
    match = re.search(r"^Pages:\s+(\d+)", out, re.M)
    return int(match.group(1)) if match else None


def is_pdf(path):
    with open(path, "rb") as f:
        return f.read(5) == b"%PDF-"


def copy(src, dest):
    shutil.copyfile(src, dest)
