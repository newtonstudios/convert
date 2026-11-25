#!/usr/bin/env bash
# Converts generated samples to every format this machine offers for them.
#
#   ./smoke-test.sh                 use a temporary folder, remove it afterwards
#   ./smoke-test.sh --out DIR       keep the results in DIR
#   ./smoke-test.sh --keep          keep the temporary folder and print its path
#   ./smoke-test.sh --strict        a format skipped for a missing tool is a failure (what CI does)
#
# The format list is not written down here: each sample is asked what it can become, which is the
# same list the picker shows, so a format that stops being offered shows up as skipped.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
export PYTHONPATH="$ROOT/src"
PYTHON=${PYTHON:-python3}

OUT=""
KEEP=0
STRICT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#*=}"; shift ;;
    --keep) KEEP=1; shift ;;
    --strict) STRICT=1; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$OUT" ]; then
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/convert-smoke.XXXXXX") || exit 1
  if [ "$KEEP" -eq 0 ]; then trap 'rm -rf "$OUT"' EXIT; fi
fi
mkdir -p "$OUT"
echo "Samples and results: $OUT"

pass=0
fail=0
skip=0
failed=()

have() { command -v "$1" >/dev/null 2>&1; }

# ── Samples ──────────────────────────────────────────────────────────────
samples=()

if have ffmpeg; then
  ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=2:sample_rate=96000" \
    -c:a pcm_s24le "$OUT/tone.wav" && samples+=("$OUT/tone.wav")
  # A video with sound, in a container the audio-only formats can be taken out of.
  ffmpeg -v error -y -f lavfi -i "testsrc=duration=2:size=320x240:rate=25" \
    -f lavfi -i "sine=frequency=330:duration=2" -shortest \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac "$OUT/clip.mov" && samples+=("$OUT/clip.mov")
fi

if have magick || have convert; then
  IM=$(command -v magick || command -v convert)
  "$IM" -size 320x200 gradient:blue-red "$OUT/photo.png" && samples+=("$OUT/photo.png")
  # Two pages, as an image-only PDF: what a scan looks like. Only the page-image
  # formats are offered for it -- there is no text in it to take out.
  "$IM" "$OUT/photo.png" "$OUT/photo.png" -density 150 "$OUT/scan.pdf" 2>/dev/null \
    && samples+=("$OUT/scan.pdf")
elif have ffmpeg; then
  ffmpeg -v error -y -f lavfi -i "color=c=blue:s=320x200:d=1" -frames:v 1 "$OUT/photo.png" \
    && samples+=("$OUT/photo.png")
fi

# A self-contained SVG (drawn by rsvg-convert, never by ImageMagick).
printf '<?xml version="1.0"?>\n<svg xmlns="http://www.w3.org/2000/svg" width="64" height="48"><rect width="64" height="48" fill="#3a7"/><circle cx="32" cy="24" r="16" fill="#fff"/></svg>\n' > "$OUT/icon.svg"
samples+=("$OUT/icon.svg")

printf '# Title\n\nSome **bold** text and a [link](https://example.com).\n\n- one\n- two\n\n```\ncode here\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n' > "$OUT/note.md"
samples+=("$OUT/note.md")
printf 'plain text, first line\nsecond line\n\nsecond paragraph\n' > "$OUT/note.txt"
samples+=("$OUT/note.txt")
printf '<!DOCTYPE html><html><head><title>Page</title></head><body><h1>Hi</h1><p>There</p></body></html>' > "$OUT/page.html"
samples+=("$OUT/page.html")

# A PDF with real text in it, so the text extractions have something to read.
# Written by hand (tests/pdf_sample.py) so this works on a machine with no
# browser and no LibreOffice, where those conversions still have to work.
if "$PYTHON" "$ROOT/tests/pdf_sample.py" "$OUT/text.pdf" 2; then
  samples+=("$OUT/text.pdf")
fi

# A font, taken from the ones the system has (a copy, never the original).
for font in /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf /usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf /usr/share/fonts/TTF/DejaVuSans.ttf; do
  if [ -f "$font" ]; then
    cp "$font" "$OUT/font.ttf" && samples+=("$OUT/font.ttf")
    break
  fi
done

if [ ${#samples[@]} -eq 0 ]; then
  echo "nothing to test with: install ffmpeg and ImageMagick" >&2
  exit 1
fi
echo

# ── Convert ──────────────────────────────────────────────────────────────
for sample in "${samples[@]}"; do
  name=$(basename "$sample")
  targets=$("$PYTHON" -m convert --targets "$sample" 2>/dev/null)
  if [ "$name" = "scan.pdf" ]; then
    targets=$(printf '%s\n' "$targets" | grep -E '^pdf-(png|jpg) ' || true)
  fi
  if [ -z "$targets" ]; then
    printf 'skip  %-12s (no format available)\n' "$name"
    skip=$((skip + 1))
    continue
  fi
  while IFS=$'\t ' read -r id _rest; do
    [ -n "$id" ] || continue
    # A test run writes next to the samples, in its own folder.
    output=$("$PYTHON" -m convert "$id" "$sample" 2>&1)
    if [ $? -eq 0 ]; then
      saved=$(printf '%s\n' "$output" | sed -n 's/^   saved as //p' | head -1)
      if [ -n "$saved" ] && [ -e "$saved" ] && [ -s "$saved" ] || { [ -n "$saved" ] && [ -d "$saved" ]; }; then
        printf 'ok    %-12s %-12s %s\n' "$name" "$id" "$(basename "$saved")"
        pass=$((pass + 1))
      else
        printf 'FAIL  %-12s %-12s output missing\n' "$name" "$id"
        fail=$((fail + 1)); failed+=("$name $id: output missing")
      fi
    else
      printf 'FAIL  %-12s %-12s %s\n' "$name" "$id" "$(printf '%s' "$output" | tr '\n' ' ')"
      fail=$((fail + 1)); failed+=("$name $id: $output")
    fi
  done <<< "$targets"
done

# ── Results that must be what they claim ─────────────────────────────────
echo
echo "--- checking a few results for what they are ---"
check() {
  what="$1"; file="$2"; shift 2
  if [ ! -e "$file" ]; then
    printf 'FAIL  %-28s %s is missing\n' "$what" "$(basename "$file")"
    fail=$((fail + 1)); failed+=("$what: missing")
    return
  fi
  if "$@" >/dev/null 2>&1; then
    printf 'ok    %s\n' "$what"
  else
    printf 'FAIL  %-28s %s\n' "$what" "$(basename "$file")"
    fail=$((fail + 1)); failed+=("$what: not what it should be")
  fi
}

if [ -f "$OUT/note.pdf" ]; then
  check "md -> pdf is A4" "$OUT/note.pdf" bash -c "pdfinfo '$OUT/note.pdf' | grep -q 'A4'"
  check "md -> pdf has the text" "$OUT/note.pdf" bash -c "pdftotext '$OUT/note.pdf' - | grep -q 'Title'"
fi
if [ -f "$OUT/text.pdf" ] && have pdfinfo; then
  check "sample pdf has 2 pages" "$OUT/text.pdf" bash -c "pdfinfo '$OUT/text.pdf' | grep -q 'Pages:.*2'"
fi
if [ -f "$OUT/text.docx" ]; then
  check "pdf -> docx is a document" "$OUT/text.docx" "$PYTHON" -c "import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); assert 'word/document.xml' in z.namelist() and b'Convert sample PDF' in z.read('word/document.xml')" "$OUT/text.docx"
fi
if [ -f "$OUT/text.odt" ]; then
  check "pdf -> odt is a document" "$OUT/text.odt" "$PYTHON" -c "import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); assert z.read('mimetype')==b'application/vnd.oasis.opendocument.text'" "$OUT/text.odt"
fi
if [ -f "$OUT/text.rtf" ]; then
  check "pdf -> rtf is RTF" "$OUT/text.rtf" bash -c "head -c 20 '$OUT/text.rtf' | grep -q 'rtf1'"
fi
if [ -f "$OUT/text.txt" ]; then
  check "pdf -> txt has the words" "$OUT/text.txt" grep -qi "extracted" "$OUT/text.txt"
fi
if [ -d "$OUT/scan pages" ]; then
  check "pdf -> png is a folder of pages" "$OUT/scan pages" test -f "$OUT/scan pages/page 1.png"
fi
if [ -f "$OUT/photo.webp" ]; then
  check "png -> webp is WebP" "$OUT/photo.webp" bash -c "file '$OUT/photo.webp' | grep -qiE 'Web/?P'"
fi
if [ -f "$OUT/tone.mp3" ]; then
  check "wav -> mp3 has a bitrate set" "$OUT/tone.mp3" bash -c "file '$OUT/tone.mp3' | grep -q 'layer III'"
fi
if [ -f "$OUT/font.woff2" ]; then
  check "ttf -> woff2 is WOFF2" "$OUT/font.woff2" bash -c "head -c 4 '$OUT/font.woff2' | grep -q wOF2"
fi

if [ -f "$OUT/icon.png" ]; then
  check "svg -> png is PNG" "$OUT/icon.png" bash -c "file '$OUT/icon.png' | grep -q 'PNG image'"
fi
# An SVG that points outside itself must be refused, not drawn.
if have rsvg-convert; then
  printf '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="8" height="8"><image xlink:href="file:///etc/hostname" width="8" height="8"/></svg>\n' > "$OUT/linked.svg"
  if "$PYTHON" -m convert png "$OUT/linked.svg" >/dev/null 2>&1 || [ -e "$OUT/linked.png" ]; then
    printf 'FAIL  an SVG linking to a local file was converted\n'
    fail=$((fail + 1)); failed+=("linked.svg: converted, should have been refused")
  else
    echo "ok    an SVG linking to a local file is refused"
  fi
fi

# Nothing half-written may be left behind.
leftovers=$(find "$OUT" -maxdepth 1 -name '*.tmp' -o -maxdepth 1 -name '.convert-*' | wc -l)
if [ "$leftovers" -ne 0 ]; then
  printf 'FAIL  %d half-written files left behind\n' "$leftovers"
  fail=$((fail + 1)); failed+=("half-written files left behind")
else
  echo "ok    no half-written files left behind"
fi

echo
echo "pass=$pass fail=$fail skip=$skip"
if [ "$fail" -ne 0 ]; then
  printf 'failed:\n'
  for item in "${failed[@]}"; do printf '  %s\n' "$item"; done
  exit 1
fi
if [ "$STRICT" -eq 1 ] && [ "$skip" -ne 0 ]; then
  echo "strict: $skip sample(s) had no format available -- install the missing tools" >&2
  exit 1
fi
exit 0
