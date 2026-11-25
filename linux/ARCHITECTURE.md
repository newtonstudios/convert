# How Convert for Linux is built

Notes for people changing the code. What the app does for its users is in the [main README](../README.md)
and in [README.md](README.md) next to this file.

The Mac app in `Sources/Convert/` is the original and the specification: target IDs, labels, defaults,
option ranges, error texts and the order of things come from there. The two apps share behaviour, not
code. Where Linux can't do something the Mac does, the format is hidden at runtime rather than offered
and failing, and the difference is listed in the README.

The Windows port (`windows/`) answered the same questions first; this port follows its split -- a core
that converts and a thin front end -- with Python and the distribution's tools where Windows used .NET
and Magick.NET.

## The shape

There is no build step and no dependency: it is a Python package that runs where it lies.

| Path | What's in it |
|---|---|
| `src/convert` | Everything, importable as `convert` |
| `src/convert/cli.py` | The command line, which is also how the file managers call it |
| `src/convert/ui.py` | The picker and progress, in `zenity` or `kdialog` |
| `install.sh`, `uninstall.sh` | Install to a prefix; add and remove the file-manager entries |
| `integration/` | The `.desktop` entries and the Nautilus script that `install.sh` copies |
| `tests/` | Unit tests for the rules that don't need a tool, and the smoke test |
| `check.sh`, `smoke-test.sh` | What CI runs, runnable locally |

| File in `src/convert` | Mac counterpart | What's in it |
|---|---|---|
| `kinds.py` | `MediaKinds.swift`, `Sniff.swift` | Accepted extensions, kind detection, what the first bytes say |
| `formats.py` | `Formats.swift` | Output formats, per-format options, settings, what is available |
| `tools.py` | `Process.swift`, `Tools.cs` | Finding the tools, asking what they can do, running one, Stop |
| `paths.py` | `Paths.swift` | Output names, the Downloads fallback, temp folders |
| `media.py` | `FFmpeg.swift` | ffmpeg arguments, and which GPU encoder works |
| `images.py` | `ImageConv.swift` | Images, through ImageMagick (decoder named, own policy in `magick/`); SVG through `rsvg-convert` |
| `docs.py`, `markdown.py` | `DocConv.swift`, `Markdown.swift` | Documents: LibreOffice, browser printing, Markdown → HTML |
| `htmlclean.py` | `DocBrowser.cs` (`CleanScript`) | HTML made safe to print or hand to LibreOffice |
| `pdfs.py`, `docwrite.py` | `DocConv.swift`, `PDFText.swift`, `DocWriter*.cs` | PDF → images, text, Word/ODT/RTF |
| `fonts.py` | `FontConv.swift`, `SFNT.swift`, `WOFF.swift`, `WOFF2.swift` | Fonts, through fontTools |
| `core.py` | `Converter.swift` | One conversion, and a batch of them |

## The rules every conversion follows

1. **The kind comes from the name**, except where the name can't be trusted. `.ts` is TypeScript or an
   MPEG transport stream, so its first bytes decide (`kinds.kind_of`).
2. **The contents have to agree with the name.** A JPEG renamed to `.mp3` gets a sentence saying so
   and what to rename it to, not a decoder's error (`kinds.verify`).
3. **A format that can't be produced is hidden.** `formats.available` asks the tool: the encoder list
   from `ffmpeg -encoders`, a two-pixel write for HEIC/AVIF/PDF with ImageMagick, `fontTools` and
   Brotli for WOFF2, the presence of `soffice`, `pdftoppm`, `pdftotext` and a browser.
4. **Nothing is overwritten.** The output name is chosen first (`name.ext`, then `name 2.ext`), and
   the finished file is moved into place with `os.link`, which fails rather than replaces if the name
   was taken meanwhile (`paths.move_into_place`).
5. **Nothing half-written is left.** Every conversion works in `~/.cache`-free temp folders under
   `$TMPDIR/convert/<uuid>`, and only the finished result is moved out. A failure removes it; Stop
   removes it; a crash is cleaned up by the next run, which deletes folders older than a day.
6. **The original's folder, or Downloads.** If the folder can't be written to -- asked by creating a
   file, not by looking at permissions -- the result goes to the XDG download folder
   (`paths.folder_for`).
7. **Stop ends the process tree**, not just its first process: LibreOffice and a browser both start
   children, so each tool runs in its own process group (`tools._kill_tree`).

## Why the tools and not libraries

The Mac has ImageIO, CoreText and PDFKit; Linux distributions do not ship equivalents to Python, and
the alternative -- Pillow, PyMuPDF, python-docx, and their native wheels -- is dependencies to bundle
and keep current, which this project doesn't do. A distribution's tools are already installed, already
updated, and already trusted by the person running them. Where that isn't true the format is hidden.

The two exceptions are deliberate:

- **Markdown → HTML** (`markdown.py`) is Convert's own, so Markdown → PDF, HTML and text need nothing
  installed, and the output is the same on every machine.
- **PDF → Word/ODT/RTF** (`docwrite.py`) writes the files itself, so a text extraction doesn't need
  LibreOffice. It is the smallest correct DOCX, ODT and RTF that Word and LibreOffice open without
  complaint; the tests check the structure, not just that a file appeared.

## Caching

`tools.py` caches what a tool can do, not whether it is installed: answers are looked up by the tool's
path, so installing ffmpeg's extra encoders or upgrading ImageMagick is picked up by the next run
within the same process, and a new file manager entry needs no restart. The probes are one command
each (`-encoders`, a two-pixel image write), which is why they can run on every window opening.

## Tests

`tests/test_units.py` covers the rules above and the writers, with no external tool. `smoke-test.sh`
does real conversions of generated samples through every format the machine offers, checks the results
are what they claim (`file`, `pdfinfo`, the DOCX and ODT zip structure), and reports what it skipped.
CI runs both on Ubuntu with ffmpeg, ImageMagick, poppler and fontTools installed.
