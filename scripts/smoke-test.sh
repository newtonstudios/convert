#!/bin/bash
# Conversion smoke test: generates small sample files and converts each one to
# every output format the app offers for it, using the app's --cli mode.
#
#   scripts/smoke-test.sh [--strict] [--out DIR] [--keep] [BINARY]
#
#   BINARY    the Convert executable (default: build/Convert.app/Contents/MacOS/Convert;
#             run ./build.sh first, or use `scripts/check.sh smoke`, which builds for you)
#   --strict  missing ffmpeg/ffprobe/cwebp is a failure (CI uses this). Without it,
#             formats that need a missing tool are reported as SKIP.
#   --out DIR keep samples, outputs and per-conversion logs in DIR (default: a temp folder,
#             deleted afterwards unless something failed or --keep is given)
#
# A conversion passes when the app exits 0, prints no FAIL line, and writes at least one
# non-empty file. Each conversion gets $SMOKE_TIMEOUT seconds (default 120).
#
# One conversion of every kind also runs from a read-only folder, where the output has to
# go to the fallback folder instead.
#
# Font samples are copies of fonts that come with macOS; nothing is committed. Converted
# fonts are also checked for the right first bytes.
#
# Formats with a hardware encoder (H.264, HEVC, ProRes, MKV) also run with hardware
# encoding off. On a machine without such an encoder (e.g. GitHub's macOS VMs) the hardware
# run still has to pass: the app falls back to the software encoder by itself.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

STRICT=0 KEEP=0 OUT="" BIN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict) STRICT=1 ;;
    --keep) KEEP=1 ;;
    --out) OUT="${2:?--out needs a directory}"; shift ;;
    -h|--help) sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) BIN="$1" ;;
  esac
  shift
done
BIN="${BIN:-build/Convert.app/Contents/MacOS/Convert}"
TIMEOUT="${SMOKE_TIMEOUT:-120}"
HW_TARGETS=" mp4-h264 mkv mp4-hevc mov-prores "

if [[ ! -x "$BIN" ]]; then
  echo "No Convert binary at $BIN. Run ./build.sh first (or scripts/check.sh smoke)." >&2
  exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

if [[ -z "$OUT" ]]; then
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/convert-smoke.XXXXXX")"
else
  rm -rf "$OUT" && mkdir -p "$OUT"
fi
OUT="$(cd "$OUT" && pwd)"
SAMPLES="$OUT/samples" RUNS="$OUT/runs"
mkdir -p "$SAMPLES" "$RUNS"

PASSED=0 SKIPPED=0 FAILURES="" COVERED=" "

# The app looks for its tools in these folders (see Tools in Process.swift), not on $PATH.
tool() {
  local d
  for d in /opt/homebrew/bin /usr/local/bin /usr/bin; do
    [[ -x "$d/$1" ]] && { echo "$d/$1"; return 0; }
  done
  return 1
}
FFMPEG="$(tool ffmpeg || true)"
FFPROBE="$(tool ffprobe || true)"
CWEBP="$(tool cwebp || true)"

pass() { PASSED=$((PASSED + 1)); printf 'PASS  %-14s %-11s %s\n' "$1" "$2" "$3"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf 'SKIP  %-14s %-11s %s\n' "$1" "$2" "$3"; }
fail() {
  FAILURES="$FAILURES$(printf '%-14s %-11s %s' "$1" "$2" "$3")"$'\n'
  printf 'FAIL  %-14s %-11s %s\n' "$1" "$2" "$3"
}

# run_conversion <label> <target> <sample file> [settings JSON]
run_conversion() {
  local label="$1" target="$2" sample="$3" settings="${4:-}"
  local base dir input log status
  base="$(basename "$sample")"
  dir="$RUNS/$base-$label"
  mkdir -p "$dir" && cp "$sample" "$dir/"
  input="$dir/$base" log="$dir/output.log"
  # macOS has no `timeout`; perl's alarm kills the app if a conversion hangs.
  if [[ -n "$settings" ]]; then
    CONVERT_SETTINGS="$settings" perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIN" --cli "$target" "$input" >"$log" 2>&1
  else
    perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIN" --cli "$target" "$input" >"$log" 2>&1
  fi
  status=$?
  local outputs
  outputs="$(find "$dir" -type f -size +0 ! -name output.log ! -path "$input" | wc -l | tr -d ' ')"
  if [[ $status -eq 142 ]]; then
    fail "$label" "$(basename "$sample")" "timed out after ${TIMEOUT}s"
  elif grep -q '^FAIL' "$log" || [[ $status -ne 0 ]]; then
    fail "$label" "$(basename "$sample")" "$(grep -m1 '^FAIL' "$log" || tail -n1 "$log") (exit $status)"
  elif [[ "$outputs" -eq 0 ]]; then
    fail "$label" "$(basename "$sample")" "no output file written"
  else
    pass "$label" "$(basename "$sample")" "$(sed -n 's/^OK *//p' "$log" | head -n1)"
  fi
}

# Whether ffmpeg can use this encoder here (hardware encoders are missing on most VMs).
encoder_works() {
  "$FFMPEG" -v error -f lavfi -i testsrc2=size=320x240:rate=30:duration=0.5 -c:v "$1" -f null - >/dev/null 2>&1
}

echo "Convert smoke test"
echo "  app:     $BIN"
echo "  ffmpeg:  ${FFMPEG:-not installed}"
echo "  cwebp:   ${CWEBP:-not installed}"
echo "  output:  $OUT"
echo

# --- Tools ---------------------------------------------------------------------------

ALL_TARGETS="$("$BIN" --cli 2>&1 | sed -n 's/^targets: //p')"
if [[ -z "$ALL_TARGETS" ]]; then
  echo "Couldn't read the target list from '$BIN --cli'." >&2
  exit 1
fi

if [[ -z "$FFMPEG" || -z "$FFPROBE" ]]; then
  if [[ $STRICT -eq 1 ]]; then
    fail "ffmpeg" "-" "ffmpeg/ffprobe not installed (brew install ffmpeg)"
  else
    echo "Note: ffmpeg isn't installed, so audio and video formats are skipped (brew install ffmpeg)."
  fi
fi
if [[ " $ALL_TARGETS " != *" webp "* ]]; then
  # The app only offers WebP when cwebp is installed.
  if [[ $STRICT -eq 1 ]]; then
    fail "webp" "-" "WebP isn't offered: cwebp not installed (brew install webp)"
  else
    skip "webp" "-" "cwebp not installed (brew install webp)"
  fi
  COVERED="$COVERED webp "
fi

# --- Samples (generated, nothing committed) -------------------------------------------

cat >"$SAMPLES/sample.md" <<'EOF'
# Smoke test

Some **bold**, *italic* and `code`, plus a [link](https://example.com).

1. First
2. Second
   - nested item

- [x] done
- [ ] open

| Format | Engine |
|--------|--------|
| PDF    | AppKit |

> A quote.

```swift
print("hello")
```
EOF

# A TypeScript file: .ts is also the extension of MPEG transport streams (stream.ts below),
# so the app has to look inside to tell them apart.
cat >"$SAMPLES/script.ts" <<'EOF'
export function greet(name: string): string {
  return `Hello, ${name}!`;
}

console.log(greet("smoke test"));
EOF

cat >"$SAMPLES/sample.txt" <<'EOF'
Smoke test

Plain text with some accents: café, naïve, Zürich.
A second paragraph.
EOF

# The PDF comes from the app itself (Markdown → PDF), so it has real, extractable text.
# If that fails, every PDF format is reported as failed below.
mkdir -p "$OUT/pdf-sample"
cp "$SAMPLES/sample.md" "$OUT/pdf-sample/"
if perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIN" --cli pdf-doc "$OUT/pdf-sample/sample.md" >"$OUT/pdf-sample/output.log" 2>&1 \
  && [[ -s "$OUT/pdf-sample/sample.pdf" ]]; then
  cp "$OUT/pdf-sample/sample.pdf" "$SAMPLES/sample.pdf"
fi

if [[ -n "$FFMPEG" ]]; then
  ff() { "$FFMPEG" -v error -y "$@"; }
  # Hi-res stereo WAV: 24-bit, 96 kHz.
  ff -f lavfi -i "sine=frequency=440:sample_rate=96000:duration=2" -ac 2 -c:a pcm_s24le "$SAMPLES/sample.wav"
  # Short video with a soundtrack.
  ff -f lavfi -i "testsrc2=size=320x240:rate=30:duration=2" -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=2" \
    -c:v mpeg4 -q:v 5 -pix_fmt yuv420p -c:a aac -shortest "$SAMPLES/sample.mp4"
  ff -f lavfi -i "testsrc2=size=320x240" -frames:v 1 "$SAMPLES/sample.png"
  # A real MPEG transport stream, the other meaning of .ts.
  ff -f lavfi -i "testsrc2=size=320x240:rate=30:duration=2" -f lavfi -i "sine=frequency=660:sample_rate=48000:duration=2" \
    -c:v mpeg2video -q:v 5 -pix_fmt yuv420p -c:a mp2 -shortest -f mpegts "$SAMPLES/stream.ts"
elif [[ -f "$SAMPLES/sample.pdf" ]]; then
  sips -s format png "$SAMPLES/sample.pdf" --out "$SAMPLES/sample.png" >/dev/null
fi

# Fonts: a TrueType font and a collection that come with macOS, plus that font as WOFF and
# WOFF2, made by the app itself (so those two formats are also read, not just written).
first_file() {
  local f
  for f in "$@"; do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}
FONTS=/System/Library/Fonts
if font="$(first_file $FONTS/Monaco.ttf $FONTS/Geneva.ttf $FONTS/Supplemental/Arial.ttf)"; then
  cp "$font" "$SAMPLES/sample.ttf"
fi
if font="$(first_file $FONTS/Noteworthy.ttc $FONTS/MarkerFelt.ttc $FONTS/Courier.ttc $FONTS/Helvetica.ttc)"; then
  cp "$font" "$SAMPLES/sample.ttc"
fi
if [[ -f "$SAMPLES/sample.ttf" ]]; then
  mkdir -p "$OUT/font-sample"
  cp "$SAMPLES/sample.ttf" "$OUT/font-sample/"
  for target in font-woff font-woff2; do
    perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIN" --cli "$target" "$OUT/font-sample/sample.ttf" >>"$OUT/font-sample/output.log" 2>&1
  done
  for ext in woff woff2; do
    [[ -s "$OUT/font-sample/sample.$ext" ]] && cp "$OUT/font-sample/sample.$ext" "$SAMPLES/"
  done
fi

# --- Hardware encoders ----------------------------------------------------------------

HW_OK=" "
if [[ -n "$FFMPEG" ]]; then
  for enc in h264_videotoolbox hevc_videotoolbox prores_videotoolbox; do
    if encoder_works "$enc"; then HW_OK="$HW_OK$enc "; fi
  done
  echo "Hardware encoders here:${HW_OK% } (formats whose encoder is missing test the software fallback)"
  echo
fi

# --- Conversions ----------------------------------------------------------------------

NEEDS_FFMPEG=" sample.mp4 stream.ts sample.wav sample.png "
for name in sample.mp4 stream.ts sample.wav sample.png sample.md sample.txt script.ts sample.pdf \
  sample.ttf sample.ttc sample.woff sample.woff2; do
  sample="$SAMPLES/$name"
  # Ask the app which formats it offers for this file (same logic as the window). It may look
  # inside the file, so ask about the sample itself; an empty stand-in is only for a sample
  # that couldn't be generated.
  probe="$sample"
  if [[ ! -f "$sample" ]]; then
    probe="$OUT/probe/$name"
    mkdir -p "$OUT/probe" && : >"$probe"
  fi
  targets="$("$BIN" --cli --targets "$probe")" || {
    fail "-" "$name" "app doesn't recognise this file type: $targets"
    continue
  }
  targets="$(echo $targets)"   # one line, single spaces

  # The two .ts files must be told apart by their contents.
  if [[ $name == script.ts && " $targets " != *" pdf-doc "* ]]; then
    fail "-" "$name" "a TypeScript file should be offered document formats, got: $targets"
  elif [[ $name == stream.ts && -f "$sample" && " $targets " != *" mp4-h264 "* ]]; then
    fail "-" "$name" "a transport stream should be offered video formats, got: $targets"
  fi

  for target in $targets; do
    COVERED="$COVERED$target "
    if [[ ! -f "$sample" ]]; then
      if [[ -z "$FFMPEG" && "$NEEDS_FFMPEG" == *" $name "* && $STRICT -eq 0 ]]; then
        skip "$target" "$name" "ffmpeg not installed"
      else
        fail "$target" "$name" "sample couldn't be created (see the logs in $OUT)"
      fi
      continue
    fi

    if [[ "$HW_TARGETS" == *" $target "* ]]; then
      run_conversion "$target" "$target" "$sample"
      run_conversion "$target+sw" "$target" "$sample" '{"hardware": false}'
    else
      run_conversion "$target" "$target" "$sample"
    fi
  done
done

# --- Fonts ----------------------------------------------------------------------------
# Every converted font starts with the bytes of the format that was asked for. A collection
# becomes a folder with one font per file.

font_check() {  # font_check <sample> <target> <first bytes as hex>…
  local sample="$1" target="$2" dir="$RUNS/$1-$2" label="$2:bytes" bad="" count=0 f head
  shift 2
  [[ -d "$dir" ]] || return 0   # the conversion itself already failed or was skipped above
  while IFS= read -r f; do
    count=$((count + 1))
    head="$(head -c 4 "$f" | xxd -p)"
    [[ " $* " == *" $head "* ]] || bad="$bad $(basename "$f")=$head"
  done < <(find "$dir" -type f -size +0 ! -name output.log ! -path "$dir/$sample")
  if [[ -n "$bad" ]]; then
    fail "$label" "$sample" "not the format asked for:$bad"
  elif [[ $sample == sample.ttc && $count -lt 2 ]]; then
    fail "$label" "$sample" "a collection should become several fonts, got $count"
  elif [[ $count -gt 0 ]]; then
    pass "$label" "$sample" "$count file(s) start with $*"
  fi
}
for sample in sample.ttf sample.ttc sample.woff sample.woff2; do
  font_check "$sample" font-woff2 774f4632                 # wOF2
  font_check "$sample" font-woff 774f4646                  # wOFF
  font_check "$sample" font-desktop 00010000 4f54544f 74727565   # TrueType, OTTO, true
done

# --- Document → PDF --------------------------------------------------------------------
# The paper size setting is respected, and nothing is logged along the way (a file given by
# a relative path used to produce CFURL warnings).

# macOS 26.6 rounds A4 to whole points, so the expected box can be a regex alternative.
paper_check() {  # paper_check <label> <settings JSON> <expected MediaBox width and height, as a regex>
  local label="$1" settings="$2" box="$3" dir="$RUNS/paper-$1" log
  mkdir -p "$dir" && cp "$SAMPLES/sample.md" "$dir/"
  log="$dir/output.log"
  (cd "$dir" && CONVERT_SETTINGS="$settings" perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIN" --cli pdf-doc sample.md) >"$log" 2>&1
  local status=$?
  if [[ $status -ne 0 ]] || grep -q '^FAIL' "$log"; then
    fail "$label" "sample.md" "$(grep -m1 '^FAIL' "$log" || tail -n1 "$log") (exit $status)"
  elif ! grep -a -q -E "/MediaBox \[0 0 ($box)\]" "$dir/sample.pdf"; then
    fail "$label" "sample.md" "wrong paper size: $(grep -a -o -m1 '/MediaBox \[[^]]*\]' "$dir/sample.pdf")"
  elif grep -q -v '^OK ' "$log"; then
    fail "$label" "sample.md" "unexpected output: $(grep -v -m1 '^OK ' "$log")"
  else
    pass "$label" "sample.md" "$(grep -a -o -m1 '/MediaBox \[[^]]*\]' "$dir/sample.pdf" | tr -d /), nothing logged"
  fi
}
paper_check "pdf-doc:a4" '{"paperA4": true}' '595\.2756 841\.8898|595 842'
paper_check "pdf-doc:letter" '{"paperA4": false}' "612 792"

# --- Read-only source folder ----------------------------------------------------------
# When the original's folder can't be written to, the output goes to a fallback folder
# (Downloads; CONVERT_FALLBACK_DIR points it at a folder of ours) and the app says so.
# One conversion of every kind.

RO="$OUT/read-only" FALLBACK="$OUT/fallback"
RO_CASES="sample.png:jpg sample.wav:mp3 sample.mp4:gif sample.md:pdf-doc sample.txt:docx sample.pdf:pdf-png sample.pdf:pdf-txt sample.pdf:pdf-docx sample.ttf:font-woff2"
mkdir -p "$RO" "$FALLBACK"
for pair in $RO_CASES; do
  [[ -f "$SAMPLES/${pair%%:*}" ]] && cp "$SAMPLES/${pair%%:*}" "$RO/"
done
chmod a-w "$RO"
for pair in $RO_CASES; do
  name="${pair%%:*}" target="${pair##*:}" label="read-only:${pair##*:}"
  if [[ ! -f "$RO/$name" ]]; then
    if [[ -z "$FFMPEG" && "$NEEDS_FFMPEG" == *" $name "* && $STRICT -eq 0 ]]; then
      skip "$label" "$name" "ffmpeg not installed"
    else
      fail "$label" "$name" "sample couldn't be created"
    fi
    continue
  fi
  log="$RUNS/read-only-$name-$target.log"
  before="$(find "$FALLBACK" -type f -size +0 | wc -l | tr -d ' ')"
  CONVERT_FALLBACK_DIR="$FALLBACK" perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIN" --cli "$target" "$RO/$name" >"$log" 2>&1
  status=$?
  after="$(find "$FALLBACK" -type f -size +0 | wc -l | tr -d ' ')"
  if [[ $status -ne 0 ]] || grep -q '^FAIL' "$log"; then
    fail "$label" "$name" "$(grep -m1 '^FAIL' "$log" || tail -n1 "$log") (exit $status)"
  elif [[ "$after" -le "$before" ]]; then
    fail "$label" "$name" "nothing was written to the fallback folder"
  elif ! grep -q "saved to $FALLBACK" "$log"; then
    fail "$label" "$name" "the app didn't say where it saved the file"
  else
    pass "$label" "$name" "saved to the fallback folder"
  fi
done
chmod u+w "$RO"

# Every format the app lists must have been tried by at least one sample.
for target in $ALL_TARGETS; do
  if [[ "$COVERED" != *" $target "* ]]; then
    fail "$target" "-" "no sample covers this format; add one to scripts/smoke-test.sh"
  fi
done

# --- Summary --------------------------------------------------------------------------

FAILED=$(printf '%s' "$FAILURES" | grep -c . || true)
echo
echo "$PASSED passed, $FAILED failed, $SKIPPED skipped"
if [[ $FAILED -gt 0 ]]; then
  echo
  echo "Failed formats:"
  printf '%s' "$FAILURES" | sed 's/^/  /'
  echo
  echo "Samples, outputs and logs: $OUT"
  exit 1
fi
if [[ $KEEP -eq 0 ]]; then rm -rf "$OUT"; fi
exit 0
