# Convert for Windows

The Windows version of Convert. Right-click files in Explorer → **Convert…** → pick a format → the new
file lands next to the original. Everything runs on your PC; nothing is uploaded.

On Windows 11 it sits directly in the context menu (not under "Show more options"); on Windows 10 it is
in the usual right-click menu. The window follows your light or dark theme and accent colour.

It does what the Mac app does at version 0.4 (see the [main README](../README.md) for the formats and
settings), with the differences listed under [Differences from the Mac app](#differences-from-the-mac-app).

## Requirements

- Windows 11, or Windows 10 version 2004 or later (x64). Windows 10 has been tested less.
- The [.NET 10 SDK](https://dotnet.microsoft.com/download) to build: `winget install Microsoft.DotNet.SDK.10`
- **ffmpeg** for audio and video: `winget install Gyan.FFmpeg`
  (or put `ffmpeg.exe` and `ffprobe.exe` in `windows\tools\ffmpeg\`, and `build.ps1` bundles them)
- Optional: **LibreOffice** for Word, ODT and RTF documents:
  `winget install TheDocumentFoundation.LibreOffice`

Images, PDFs (to images, text, Word, ODT and RTF), fonts, and Markdown, plain text and HTML → PDF, HTML
or text work without anything extra. ffmpeg and LibreOffice can be installed later: Convert notices
without a restart.

The repository must be in a folder whose path has no `'`, `;` or `%`, because the .NET build tools
can't handle those. If no Windows SDK is installed, `build.ps1` downloads Microsoft's packaging tools
once from nuget.org: one fixed version, checked against a known fingerprint before it is used.

## Install

```powershell
cd windows
.\build.ps1 -Install
```

This builds Convert, copies it to `%LOCALAPPDATA%\Programs\Convert` and adds **Convert…** to Explorer's
right-click menu. Convert also appears in the Start menu, where you can open it and drag files onto the
window.

### About the certificate

Windows only adds context-menu entries from signed packages. So each install makes a new certificate
named "CN=Convert Dev", signs the package with it, and deletes the certificate's private key right
away. Then Windows asks once for permission (UAC) to trust that certificate on this PC.

Trusting it means: Windows accepts packages signed with this certificate. Because the key is already
deleted, the only package that can ever carry that signature is the one you just built. The certificate
is valid for 30 days; Convert keeps working after that. The trust entry stays until you uninstall, and
the next install replaces it. Nothing is sent anywhere.

A plain `.\build.ps1` (without `-Install`) builds an unsigned package and creates no certificate.

## Uninstall

```powershell
.\uninstall.ps1          # removes the context menu, the program, the certificate and its trust entry
.\uninstall.ps1 -All     # also removes your settings and Convert's temporary files
.\uninstall.ps1 -WhatIf  # only shows what would be removed
```

Removing the trust entry needs one permission prompt. If you say No, the script tells you what is left
and how to finish. It always ends with a list of what was removed and what, if anything, is left.

## Making a release

Releases are built and signed by GitHub Actions (see [Signed releases](#signed-releases)): publishing a
release on GitHub is all it takes. To build a signed setup program on your own PC instead:

```powershell
.\build.ps1 -Setup -CertificateThumbprint <thumbprint> -TimestampUrl <your certificate authority's timestamp server>
```

This builds `out\Convert-<version>-setup.exe` (about 16 MB): one file people download and run. It needs
[Inno Setup 6](https://jrsoftware.org/isinfo.php) (`winget install JRSoftware.InnoSetup`) and a
code-signing certificate in your personal certificate store; list yours with
`Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert`. The certificate's subject becomes the package's
publisher, and the app's own files, the package, the setup program and its uninstaller are all signed
with it.

What the setup program does on someone's PC:

- It installs for that user only, into `%LOCALAPPDATA%\Programs\Convert`, and never asks for
  administrator rights itself.
- The download doesn't contain .NET. If the PC has no .NET 10 Desktop Runtime, the setup program
  fetches Microsoft's installer for it (about 57 MB, the version and SHA-256 pinned in `build.ps1`),
  checks it and runs it; that installer asks for permission once. Bump the pin with each release.
- It runs `Convert.exe --register-menu`, which adds **Convert…** to Explorer's right-click menu. If
  Windows refuses (it only accepts a package whose signature it trusts), Convert is still installed and
  gets a Start menu shortcut, and the setup program says what happened.
- Running a newer setup program over an installed Convert updates it. Uninstalling from
  **Settings → Apps** takes the menu entry out, removes the program and asks whether to remove the
  settings too.

To try the setup program before you have a certificate:

```powershell
.\build.ps1 -Setup -TestSign   # signs like -Install does and asks once (UAC) to trust that certificate here
.\out\Convert-0.4.0-setup.exe
```

A setup program made with `-TestSign` only works on the PC that built it. `.\uninstall.ps1` removes a
Convert installed either way, and the test certificate's trust entry.

Even with a real certificate, Windows SmartScreen warns about a download from a publisher it hasn't
seen often yet; that goes away as more people install it.

### Signed releases

Releases are signed through [SignPath Foundation](https://signpath.org), which provides free code
signing for open-source projects (see the [code signing policy](../README.md#code-signing-policy)). The
certificate belongs to SignPath Foundation and never leaves SignPath: GitHub Actions builds Convert,
sends the files to SignPath, and gets them back signed once someone in the project approves the request
there. `.github/workflows/windows-setup.yml` does this when a release is published (or when it is run by
hand with **sign** ticked), in two signing requests, because the setup program contains the signed files:

1. `build.ps1 -Publisher "<the certificate's subject>"` builds the app and the package with SignPath's
   certificate as the publisher (Windows only registers a package whose publisher is the signer, letter
   for letter). SignPath signs `Convert.exe`, `Convert.dll`, `Convert.Core.dll`, `Convert.Shell.dll`
   and `Convert.msix` ([`signing/windows-app.xml`](signing/windows-app.xml)).
2. `build.ps1 -SetupFrom out\app` packs the signed files into the setup program without building or
   signing anything, and SignPath signs that ([`signing/windows-setup.xml`](signing/windows-setup.xml)).

The workflow then checks every signature, installs the setup program on the runner, checks that
**Convert…** made it into Explorer's menu, runs the smoke test, uninstalls, and attaches the setup program
to the release as `Convert-setup.exe` (with its SHA-256). The release tag must be `v` plus `<Version>`
in `Directory.Build.props`. Every file's product name is "Convert" and its product version exactly that
version; SignPath refuses to sign anything else.

The two XML files are copies of the artifact configurations in the SignPath project: SignPath uses its
own, so change both together. The workflow reads its settings from the repository: the variables
`SIGNPATH_ORGANIZATION_ID` and `SIGNPATH_PUBLISHER` (the certificate's subject exactly as Windows shows
it, e.g. in `(Get-AuthenticodeSignature Convert.exe).SignerCertificate.Subject`), the secret
`SIGNPATH_API_TOKEN`, and optionally `SIGNPATH_PROJECT_SLUG` (default `convert`) and
`SIGNPATH_SIGNING_POLICY_SLUG` (default `release-signing`). Without `SIGNPATH_ORGANIZATION_ID` it
builds an unsigned setup program, as before; pull requests never sign.

The uninstaller inside the setup program isn't signed: Inno Setup signs it while it compiles, and
SignPath can only sign the finished setup program.

## Privacy

Convert has no network code, no analytics and no update check. It reads the files you give it and
writes the converted files next to them (or to Downloads, when their folder is read-only).

Converting a document never touches the network either. Pictures, fonts and styles a document links to
on the web or on a network share are left out; only files in the document's own folder are used. Local
pictures are embedded in Word and OpenDocument output instead of linked, and converted files don't
contain the original's folder or your user name.

## Differences from the Mac app

The formats, their IDs, the settings and their defaults are the Mac's
(`Sources/Convert/Formats.swift`). These are the places where Windows differs, and why.

**Formats that are only offered when the PC can write them**

- **M4A (HE-AAC)** needs an ffmpeg built with `libfdk_aac`, which the usual builds (winget's included)
  don't have. Without it the format isn't listed.
- **HEIC** output uses Windows' own encoder and needs the free *HEIF Image Extensions* and the *HEVC
  Video Extensions* from the Microsoft Store. Without them HEIC isn't listed. (Reading HEIC always works.)
- **AVIF** and **WebP** are written by Magick.NET and are always there in practice; they're checked
  rather than assumed. No separate `cwebp` is needed.

**Things that work differently**

- **Word, ODT and RTF documents** (in or out) need LibreOffice; the Mac uses `textutil`, which is part
  of macOS. Without LibreOffice the window says so when such a conversion is chosen.
- **Paper size** (A4 / US Letter) applies to Markdown, text and HTML. Word, ODT and RTF files keep the
  page setup they have. A4 pages come out as 594.96 × 841.92 pt, a rounding by the print engine.
- **Remote content in documents** is never loaded: remote pictures, web fonts and linked stylesheets
  don't appear in converted documents, and links to local files are removed from PDFs.
- **Hardware encoding** uses whichever of NVIDIA (NVENC), Intel (Quick Sync) or AMD (AMF) passes a short
  test, for H.264, HEVC and MKV. ProRes has no hardware encoder on Windows, so MOV (ProRes) has no
  "Hardware encoding" option.
- **AAC** is encoded by ffmpeg's own encoder; the Mac uses Apple's.
- **PDF to Word, ODT and RTF** reads the text in the order the PDF draws it, so a PDF that draws its
  text out of reading order can come out reordered. Fonts are named after the PDF's font names
  ("Helvetica", "Times"), which Word and LibreOffice replace with what's installed.
- **WOFF2** is always compressed at Brotli's highest setting, which comes with .NET; the Mac only gets
  that when the `brotli` tool is installed. It takes a few seconds for a typical font and a minute or
  more for a large Chinese, Japanese or Korean one. Stop works at once, but one processor core stays
  busy until the compressor finishes the step it is in.
- **Stop during a large image** takes effect when the encoder returns (some seconds for a very large
  AVIF); nothing is left behind.
- **The label "Word 97–2003 (DOC)"** is "Word 97–2004" on the Mac, after Word 2004 for Mac. On Windows
  that format has always been called 97–2003.
- **The Explorer menu** decides by the file name alone, so it appears at once for any selection; a
  `.ts` file that turns out to be TypeScript is recognised when the window opens.
- **Move original to Recycle Bin** leaves the original where it is, and says so, when it can't be
  recycled: on network shares, on drives without a Recycle Bin, and for files too big for the bin.
  Windows would delete those for good.
- **Settings** are stored in `%LOCALAPPDATA%\Convert\settings.json`.

**Limitations shared with the Mac app**: see the main README. In particular PDF to Word carries over
text only (a paragraph that runs over a page break becomes two, hyphens at line ends stay, tables come
out as loose rows), fonts are rewrapped and never redrawn, and WOFF2 files that hold several fonts
aren't read.

**Windows-only limitations**

- Convert needs the .NET 10 Desktop Runtime on the PC; the setup program installs it when it's missing.
  Shipping .NET inside Convert instead would make the download about 90 MB and need the context-menu
  entry rewritten as a native DLL.
- HTML or Markdown converted to HTML out of a read-only folder ends up in Downloads, away from the
  pictures it refers to by relative path.
- Administrators can override the startup options of the WebView2 runtime (which prints documents to
  PDF) by policy or with `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS`. That removes two of the safeguards that
  keep document conversion off the network; the third, which checks every request, still applies.

## Development

```powershell
dotnet build            # everything
dotnet test             # unit tests; most run real conversions (ffmpeg needed for audio and video)
src\Convert\bin\Debug\net10.0-windows10.0.19041.0\win-x64\Convert.exe --cli mp3 song.opus
src\Convert\bin\Debug\net10.0-windows10.0.19041.0\win-x64\Convert.exe --cli                      # lists all format IDs
src\Convert\bin\Debug\net10.0-windows10.0.19041.0\win-x64\Convert.exe --cli --targets song.opus  # the formats offered for a file
```

`--cli` prints `OK   name → out (0.42s)` or `FAIL name: reason` per file and exits with 0, 1 (a
conversion failed) or 2 (wrong usage), like the Mac app. `CONVERT_SETTINGS` changes individual settings
(`$env:CONVERT_SETTINGS = '{"hardware": false}'`; the names are the Mac's), and `CONVERT_FALLBACK_DIR`
replaces Downloads as the folder used when the original's folder is read-only. Convert.exe is a
windowed program, so PowerShell only waits for it when its output is captured or piped.

How the code is put together is in [ARCHITECTURE.md](ARCHITECTURE.md).

### Checks

`check.ps1` runs what CI (`.github/workflows/windows.yml`) runs, from any folder:

```powershell
.\check.ps1            # everything below
.\check.ps1 format     # dotnet format --verify-no-changes; -Fix reformats
.\check.ps1 build      # build and unit tests (warnings are errors), then a release build in out\smoke-app
.\check.ps1 smoke      # rebuild the release app, then run the conversion smoke test
```

The smoke test (`smoke-test.ps1`; `-Keep`, `-Out DIR`, `-Strict`, `-RequireLibreOffice`) generates small
sample files (a 24-bit 96 kHz WAV, a short video with sound, a PNG, Markdown, plain text, a PDF and a
Word file made by the app, two `.ts` files: TypeScript and an MPEG transport stream, and fonts copied
from `C:\Windows\Fonts`) and converts each one to every format the app offers for it. Any failed
conversion fails the run and is listed by format ID; samples and logs are kept. It needs ffmpeg; without
it, audio and video formats are skipped locally (CI treats that as a failure). Conversions that need
LibreOffice are skipped when it isn't installed, also in CI, which doesn't install it. H.264, HEVC and
MKV are also tested with hardware encoding off; on a PC without a GPU encoder (like GitHub's runners),
the normal run checks that the app falls back to the software one. CI uses .NET SDK 10.0.404, whose
`dotnet format` decides the formatting; with another SDK, `format` warns that results may differ.

A few tests only run when asked for, because of what they do to the PC they run on:
`CONVERT_TEST_RECYCLE=1` puts a small file in the real Recycle Bin, and `CONVERT_FONT_SWEEP=1` converts
every font in `C:\Windows\Fonts` and back, which takes a while.
