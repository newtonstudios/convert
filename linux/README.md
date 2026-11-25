# Convert for Linux

The Linux version of Convert. Right-click files in your file manager → **Convert…** → pick a format →
the new file lands next to the original. Everything runs on your machine; nothing is uploaded.

It does what the Mac app does (see the [main README](../README.md) for the formats and settings), with
the differences listed under [Differences from the Mac app](#differences-from-the-mac-app).

## Requirements

- Linux with Python 3.9 or later (every distribution has it)
- **ffmpeg** for audio and video: `sudo apt install ffmpeg`, `sudo dnf install ffmpeg`, `sudo pacman -S ffmpeg`
- **ImageMagick** for images: `sudo apt install imagemagick`
- **poppler-utils** for PDFs (page images, text, Word): `sudo apt install poppler-utils`
- **LibreOffice** for Word, ODT and RTF documents: `sudo apt install libreoffice-writer`
- **`cwebp`** for WebP (optional -- ImageMagick also writes it): `sudo apt install webp`
- **`rsvg-convert`** for SVG files (optional): `sudo apt install librsvg2-bin`
- **fontTools** for fonts: `python3 -m pip install --user fonttools brotli`
- A **Chromium-based browser** (Chrome, Chromium, Brave or Edge) for Markdown, text and HTML → PDF,
  if LibreOffice isn't installed

Nothing is bundled and nothing is downloaded: each format uses the tool you already have. Anything
missing is **hidden** rather than offered and broken, and installing it later works without restarting
Convert (`convert-file --list-targets` shows what's available right now).

## Install

```bash
git clone https://github.com/newtonstudios/convert.git
cd convert
linux/install.sh
```

This copies Convert to `~/.local/share/convert`, puts `convert-file` in `~/.local/bin`, and adds the
right-click entries for the file managers it finds:

- **Nautilus / Files / Caja / Nemo**: right-click → **Scripts → Convert…**
- **Dolphin / Konqueror**: right-click → **Actions → Convert…**
- **Anything else**: `convert-file --ui FILE…` from a terminal, or add it to your file manager's own
  custom-action menu with that command. The app also appears in your application menu, where you can
  pass files to it.

`~/.local/bin` has to be in your `PATH` (it usually is; if `convert-file --version` says "command not
found", add `export PATH="$HOME/.local/bin:$PATH"` to your shell's start-up file).

The command is **`convert-file`**, not `convert`: on Linux `convert` is ImageMagick's, and a file
converter that took that name would break every script that calls `convert in.png out.jpg`. Use
`convert-file` wherever the examples below say so; the right-click entries don't care about the name.

Options: `linux/install.sh --prefix /usr/local` installs there instead (`sudo` then), and
`--no-integration` skips the file-manager entries.

To uninstall: `linux/uninstall.sh` (or `linux/uninstall.sh --prefix /usr/local`).

## Using it

```bash
convert-file mp3 song.opus                 # convert one file
convert-file jpg photo.heic shot.png       # several files, one format
convert-file --ui *.heic                   # the picker, like the right-click entry
convert-file --targets clip.mov            # what can this become on this machine?
convert-file --list-targets                # every format, and whether it's available
convert-file --matrix-json                 # the same list per extension, as JSON
```

Settings come from `CONVERT_SETTINGS`, or `--settings`, using the Mac app's names:

```bash
CONVERT_SETTINGS='{"audioBitrate": 192}' convert-file mp3 song.flac
convert-file --settings '{"videoQuality": 0.8, "hardware": false}' mp4-h264 clip.mov
convert-file --settings '{"pdfDPI": 300}' pdf-png scan.pdf
```

| Setting | Default | What it does |
|---|---|---|
| `audioBitrate` | 0 | kbps; 0 is MP3 VBR at its best |
| `sampleRate` | 0 | 0 keeps the source's; lossy formats are capped at 48 kHz |
| `channels` | 0 | 0 keeps the source's, 1 is mono, 2 is stereo |
| `bitDepth` | 0 | 0 matches the source, or 16 / 24 for lossless |
| `videoQuality` | 0.65 | 0 is smallest, 1 is best |
| `videoHeight` | 0 | 0 keeps the source's; never upscales |
| `fps` | 0 | 0 keeps the source's |
| `keepAudio` | true | drop the soundtrack when false |
| `hardware` | true | use the GPU encoder when there is one |
| `gifWidth`, `gifFps` | 480, 15 | animated GIF size and frame rate |
| `imageQuality` | 0.85 | for JPEG, WebP, AVIF, HEIC, TIFF and PDF |
| `maxSize` | 0 | longest edge in pixels; 0 keeps the size, never upscales |
| `paperA4` | true | A4, or US Letter when false |
| `pdfDPI` | 150 | resolution for PDF → images (72 / 150 / 300) |

`CONVERT_FALLBACK_DIR` replaces `~/Downloads` as the folder used when the original's folder is
read-only (a mounted ISO, a read-only share).

## What each format uses

| Kind | Tool | Notes |
|---|---|---|
| Audio & video | `ffmpeg` | NVENC, QSV or AMF hardware encoding when the GPU is really there; software otherwise, and a failed hardware encode is retried in software |
| Images | ImageMagick (`magick` or `convert`), `cwebp` for WebP, `rsvg-convert` for SVG | HEIC, AVIF and PDF are offered only when this ImageMagick can write them |
| Documents | LibreOffice for Word/ODT/RTF; a Chromium browser for Markdown, text and HTML → PDF | LibreOffice runs with a throwaway profile, so your own documents and settings are never touched |
| PDF | `pdftoppm` for pages, `pdftotext` for text, Convert itself for Word/ODT/RTF | |
| Fonts | `fontTools` | |

Documents are printed with the browser told to resolve **no** hostnames and given a proxy that isn't
there, and LibreOffice gets the same dead proxy, so a document can't make Convert fetch anything. An
HTML file is also cleaned before it is printed or handed to LibreOffice: scripts, frames, embedded
objects, stylesheet links, `<meta>` and `<base>`, event handlers and CSS `url()`s are taken out.

Images: ImageMagick is always told which decoder to use rather than left to guess from the contents,
and runs under Convert's own policy (`src/convert/magick/ImageMagick/policy.xml`), read after the
system's so it can only add restrictions: no external programs, no network, and none of the coders
that draw or read what a file tells them to (SVG, MVG, MSL, text, PostScript). SVG files never reach
ImageMagick: they're drawn by `rsvg-convert`, and only when they refer to nothing outside themselves
(an SVG that links to another file or a web address is refused).

## Differences from the Mac app

- **There's no app window.** Convert is a command with a picker (`zenity` on GNOME/XFCE/Cinnamon/MATE,
  `kdialog` on KDE), so there's nothing to drag files onto and no "Move original to Trash" checkbox.
  Everything else -- the formats, the settings, the naming, the fallback to Downloads, what a failure
  says -- is the same.
- **Hardware encoding** uses NVENC, QSV or AMF, whichever actually encodes a test frame; VAAPI is not
  used, because on a half-configured machine it fails instead of falling back.
- **PDF → Word** keeps the text as paragraphs only. The Mac also keeps fonts, sizes, bold and italic
  where the PDF has them; here the text comes from `pdftotext`, which gives the words but not the
  styling.
- **Markdown → Word/ODT/RTF** goes through HTML and LibreOffice, so it needs LibreOffice installed
  (Markdown → PDF, HTML and text don't).
- **A4 or US Letter** is applied through the page's `@page` rule, which the browser honours. A page
  that sets its own paper size keeps it.
- **Fonts:** converting *to* WOFF2 needs Brotli (`python3 -m pip install --user brotli`); the Mac uses
  macOS's own copy.

## Known limitations

Same as the Mac app, plus the Linux notes above: Excel and PowerPoint files aren't supported, PDF →
Word carries over text only, fonts never change between TrueType and CFF outlines, and converting an
image keeps only the first frame.

## Development

```bash
linux/check.sh                  # syntax check, unit tests, then the smoke test
linux/check.sh unit             # syntax check and unit tests only
linux/check.sh smoke --strict   # every format this machine can produce, and fail if one is skipped
```

The smoke test generates its own samples (a hi-res WAV, a short video with sound, a PNG, a two-page
PDF, a PDF with text, Markdown, plain text and HTML) and converts each one to every format offered for
it; any failed conversion fails the run and is listed by format ID. `--strict` also fails on formats
skipped because a tool is missing, which is what CI does.

To run without installing:

```bash
PYTHONPATH=linux/src python3 -m convert --list-targets
```

[ARCHITECTURE.md](ARCHITECTURE.md) is for people changing the code.
