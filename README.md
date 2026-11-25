<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Convert app icon" />
</p>

<h1 align="center">Convert</h1>

<p align="center">
  <strong>Like CloudConvert, but on your Mac.</strong><br />
  Right-click a file in Finder, pick a format, done. Nothing gets uploaded; every conversion runs locally on your machine.
</p>

<p align="center">
  <a href="https://github.com/newtonstudios/convert/releases/latest/download/Convert.zip"><strong>Download for Mac</strong></a>
  &nbsp;·&nbsp;
  <a href="https://convert.newtonbuilds.dev">Website</a>
</p>

<p align="center">
  <img src="docs/screenshot.png" width="460" alt="The Convert panel converting an Opus file to MP3" />
</p>

> [!NOTE]
> **This app is vibe coded.** It started as an afternoon of chatting with an AI coding assistant (Claude) and is now built in the open by a growing group of contributors. The code is small enough to read, but the app is young. Keep your originals (Convert never overwrites them anyway), and please [open an issue](../../issues) if something breaks.

---

## What it does

Select one or more files in Finder → right-click → **Quick Actions → Convert…**

A small window opens showing only the formats that make sense for what you selected. Pick one and hit **Convert**. The new file lands next to the original (`song.opus` → `song.mp3`, and if that exists, `song 2.mp3`). If the original's folder is read-only (a disk image, a locked disk), it's saved to your Downloads folder instead, and the window tells you.

- **Batches:** select as many files as you like (of the same kind: audio, video, images, documents, PDFs or fonts) and they're converted one after another with one progress bar. Video and audio can be mixed, since a video can become audio.
- **Stop:** ends the conversion that's running, whatever kind of file it is, and removes anything half-written (a partial file, or a folder with only some of a PDF's pages).
- **Move original to Trash:** tick the box and each original goes to the Trash once its conversion has finished. It only happens after the new file exists next to it, and you can always put it back from the Trash.

| You select | You can convert to |
|---|---|
| 🎵 **Audio** (mp3, wav, opus, flac, m4a, ogg, …) | MP3, M4A (AAC), M4A (HE-AAC), WAV, AIFF, FLAC, ALAC, Opus, OGG, WMA, AC3, WavPack, MP2 |
| 🎬 **Video** (mp4, mov, mkv, webm, avi, …) | MP4 (H.264 / HEVC / AV1), MOV (ProRes 422), WebM (VP9), MKV, animated GIF, **or any audio format** (pulls out the soundtrack) |
| 🖼️ **Images** (heic, jpg, png, webp, tiff, raw, svg, …) | JPEG, PNG, HEIC, AVIF, WebP, TIFF, GIF, BMP, PDF |
| 📄 **Documents** (docx, doc, odt, rtf, html, txt, md) | PDF, Word (DOCX / DOC), ODT, RTF, plain text, HTML, Markdown |
| 📕 **PDF** | PNG or JPEG images (one per page), Word (DOCX), ODT, RTF, Markdown or plain text (the text only, see below) |
| 🔤 **Fonts** (ttf, otf, ttc, woff, woff2) | WOFF2, WOFF (web fonts), TTF / OTF (desktop fonts) |

**Settings** live under **Advanced** (collapsed until you open it; remembered per format):

- **Audio:** bitrate (e.g. MP3 VBR or 320/256/192/128 kbps), sample rate, mono/stereo, 16- or 24-bit for lossless formats
- **Video:** quality slider, resolution (4K → 480p, never upscales), frame rate, keep or drop audio, hardware encoding on/off
- **GIF:** width and frame rate
- **Images:** quality slider, max size
- **Documents → PDF:** A4 or US Letter
- **PDF → images:** resolution (72 / 150 / 300 dpi)

You can also open the app on its own and drag files onto the window.

**PDF to Word** gives you the PDF's text as an editable document: paragraphs are put back together, and fonts, sizes, bold and italic are kept where the PDF has them. Pictures, tables and the page layout are not carried over, and a scanned PDF (pictures of pages) has no text to take.

**Fonts** are converted without loss: a web font and a desktop font hold the same data in a different wrapper, and Convert only changes the wrapper. A font taken out of a WOFF or WOFF2 file comes out as `.ttf` or `.otf`, whichever it was made from, and a collection (`.ttc`) becomes a folder with one file per font. Convert doesn't turn a TTF into a true OTF or back (that would mean redrawing every letter). Check a font's license before putting it on a website.

---

## Install

### 1. Install ffmpeg (needed for audio and video)

Convert uses [ffmpeg](https://ffmpeg.org) for audio and video and `cwebp` for WebP images. Images (other than WebP), documents, PDFs and fonts work without them, and you can install them later: Convert notices without a restart. The easiest way to install both is [Homebrew](https://brew.sh):

```bash
brew install ffmpeg webp
```

### 2. Get the app

**Option A: download it.** Grab `Convert.zip` from the [latest release](../../releases/latest), unzip it and move `Convert.app` into your **Applications** folder.

Convert isn't signed with a paid Apple Developer certificate, so the first time you open it macOS will say it can't verify the developer. To open it anyway:

- **macOS 15 and later:** try to open it once, then go to **System Settings → Privacy & Security**, scroll down, click **Open Anyway** and confirm.
- **macOS 14:** right-click `Convert.app` → **Open** → **Open**.

**Option B: Homebrew.**

```bash
brew tap newtonstudios/tap
brew trust newtonstudios/tap
brew install --cask newtonstudios/tap/convert
```

The same "can't verify the developer" step as above applies the first time you open it.

**Option C: build it yourself** (needs Xcode 15.3 or later):

```bash
git clone https://github.com/newtonstudios/convert.git
cd convert
./build.sh --install
```

This builds the app, puts it in `~/Applications` and sets up the right-click menu for you, so you can skip step 3.

### 3. Turn on the right-click menu

Open Convert. The window has an **Install** button for "Add Convert… to Finder's right-click menu". Click it. (It's also in the menu bar under **Convert → Install Finder Quick Action**.)

Now right-click any supported file in Finder → **Quick Actions → Convert…**

If it doesn't show up, check **System Settings → General → Login Items & Extensions → Finder** (on older macOS: **System Settings → Privacy & Security → Extensions → Finder**) and make sure **Convert** is ticked. On some setups it appears under **Services** instead of **Quick Actions**.

---

## Requirements

- macOS 14 Sonoma or later, on Apple Silicon or Intel
- `ffmpeg` for audio and video, `cwebp` for WebP (see above)

## Other platforms

The same formats, settings and naming rules run on [Windows](windows/README.md) and on
[Linux](linux/README.md), where they use the tools your distribution already has.

## Privacy

Convert has no network code, no analytics and no accounts. It reads the files you give it and writes the converted files next to them (or to Downloads, when their folder is read-only). That's it.

## Code signing policy

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).

This covers the Windows version: the setup program (`Convert-setup.exe` on the [releases page](../../releases)), Convert's own programs in it (`Convert.exe`, `Convert.dll`, `Convert.Core.dll`, `Convert.Shell.dll`) and the small package that puts **Convert…** in Explorer's right-click menu (`Convert.msix`). They are built by GitHub Actions from the source code in this repository ([`.github/workflows/windows-setup.yml`](.github/workflows/windows-setup.yml)), and every signing request is approved by hand. Libraries made by others that Convert ships with (such as Magick.NET, PdfPig, Markdig, and Microsoft's WebView2 and Windows libraries) and .NET's COM host (`Convert.Shell.comhost.dll`) are not signed by us. How it works is in [windows/README.md](windows/README.md#signed-releases).

Team roles:

- **Committers and reviewers:** [@eliasdesena](https://github.com/eliasdesena) (everyone with write access to this repository). Changes from anyone else come in as pull requests and are reviewed by one of them before they are merged.
- **Approvers:** [@eliasdesena](https://github.com/eliasdesena)

**Privacy:** This program will not transfer any information to other networked systems unless specifically requested by the user or the person installing or operating it. The one exception is the Windows setup program on a PC that doesn't have Microsoft's .NET 10 Desktop Runtime yet: it then downloads Microsoft's installer for it from `builds.dotnet.microsoft.com` (it says so on screen, and checks the download before running it). That download, and the .NET runtime and WebView2 (the part of Windows that Convert prints documents to PDF with, with its network access shut off), are Microsoft's, under the [Microsoft Privacy Statement](https://www.microsoft.com/privacy/privacystatement).

## Uninstall

1. In Convert, choose **Convert → Remove Finder Quick Action** (or delete `~/Library/Services/Convert.workflow`).
2. Delete `Convert.app`.

---

## Known limitations

- **Markdown** covers the common syntax (headings, bold, italic, lists, task lists, tables, code, quotes, links). Footnotes, HTML inside Markdown and images aren't rendered.
- **Excel and PowerPoint** files aren't supported (they'd need LibreOffice).
- **PDF to Word** carries over text only (see above).
- **Markdown export** guesses headings from the text size, and has no tables or images: a table's cells become paragraphs of their own.
- **Fonts:** no conversion between TrueType and CFF outlines (a real TTF ↔ OTF conversion), and WOFF2 files that hold several fonts aren't read.
- **Converting images** keeps only the first frame of an animated GIF or a multi-image HEIC.
- The **downloaded** app isn't notarized by Apple (see the install notes above).

## How it works (for the curious)

It's a small SwiftUI app (~4,300 lines) with no dependencies beyond what's on your Mac:

| Kind | Engine |
|---|---|
| Audio & video | `ffmpeg`, using Apple's hardware encoders (VideoToolbox) for H.264, HEVC and ProRes, and the software encoders on Macs that lack one |
| Images | Apple's ImageIO (plus `cwebp` for WebP); SVG drawings are drawn by AppKit, without loading anything they point to |
| Documents | macOS's built-in `textutil`, a small built-in Markdown renderer and writer, and AppKit's text system for PDF output (in a helper process, so a long document doesn't freeze the window) |
| PDF | Core Graphics and PDFKit |
| Fonts | Built in: the font tables are read and rewrapped directly, with zlib for WOFF and Brotli for WOFF2. WOFF2 files come out smallest when the `brotli` tool is installed (it comes with ffmpeg from Homebrew); without it, macOS's own, lighter Brotli is used, and they're about a fifth larger (still smaller than WOFF) |

The Finder menu item is a tiny Automator Quick Action (`~/Library/Services/Convert.workflow`) that runs `open -b local.convert.app <files>`.

| File | What's in it |
|---|---|
| `Sources/Convert/Formats.swift` | The list of accepted file types, file type detection, output formats, per-format options |
| `Sources/Convert/Sniff.swift` | Looks inside a file when its name can't be trusted (`.ts`, misnamed files) |
| `Sources/Convert/Converter.swift`, `Process.swift` | Runs one conversion; external tools, Stop, where output goes |
| `Sources/Convert/FFmpeg.swift` | ffmpeg arguments for each audio/video format |
| `Sources/Convert/ImageConv.swift`, `SVG.swift` | Image conversion; SVG drawings |
| `Sources/Convert/DocConv.swift`, `PDFText.swift` | Document conversion, document → PDF, PDF → images/text/Word |
| `Sources/Convert/FontConv.swift`, `SFNT.swift`, `WOFF.swift`, `WOFF2.swift` | Font conversion: TrueType/OpenType files, and the two web font wrappers |
| `Sources/Convert/Markdown.swift` | Markdown → HTML |
| `Sources/Convert/MarkdownWriter.swift` | Styled text → Markdown (documents and PDFs to Markdown) |
| `Sources/Convert/ConvertModel.swift`, `ContentView.swift` | The window and its state |
| `Sources/Convert/QuickAction.swift` | Installs/removes the Finder Quick Action |

### Testing from the command line

```bash
build/Convert.app/Contents/MacOS/Convert --cli mp3 song.opus
build/Convert.app/Contents/MacOS/Convert --cli                      # lists all format IDs
build/Convert.app/Contents/MacOS/Convert --cli --targets song.opus  # the formats offered for a file
CONVERT_SETTINGS='{"hardware": false}' build/Convert.app/Contents/MacOS/Convert --cli mp4-h264 clip.mov
```

`CONVERT_SETTINGS` changes individual settings; the names are the fields of `ConvSettings` in `Formats.swift`. `CONVERT_FALLBACK_DIR` replaces Downloads as the folder used when the original's folder is read-only.

### Checks and the smoke test

CI (`.github/workflows/ci.yml`) runs on every pull request and every push to `main`, using the same script you can run locally:

```bash
scripts/check.sh                 # everything below
scripts/check.sh format          # swift-format lint; `scripts/check.sh format --fix` reformats
scripts/check.sh build           # debug build and tests (warnings are errors), then the release app
scripts/check.sh smoke           # rebuild the release app, then run the conversion smoke test
```

The **smoke test** (`scripts/smoke-test.sh`) generates small sample files (a hi-res WAV, a short video with sound, a PNG, Markdown, plain text, a Word file, a PDF, two `.ts` files: TypeScript source and an MPEG transport stream, and fonts copied from the ones that come with macOS) and converts each one to every format the app offers for it. Any failed conversion fails the run and is listed by format ID. It needs `brew install ffmpeg webp`; without them, the formats that need them are skipped locally (CI treats that as a failure). Formats with hardware encoding (H.264, HEVC, ProRes, MKV) are also tested with it off; on a machine without a hardware encoder, the normal run checks that the app falls back to the software one.

You need Xcode 26.6 or its Command Line Tools: CI uses that version, and its `swift-format` (6.3) decides the formatting. With only the Command Line Tools, `build` and `smoke` use a native release build, since the universal app needs Xcode; CI builds and tests the universal app.

### The icon

`tools/make_icon.swift` draws the icon with SwiftUI; `build.sh` turns it into `AppIcon.icns` when that file is missing.

### Making a release

```bash
./build.sh --zip     # creates build/Convert.zip (universal, ad-hoc signed)
```

## License

[MIT](LICENSE). Do whatever you like with it.

ffmpeg and cwebp are **not** bundled; they're installed separately by you and keep their own licenses.
