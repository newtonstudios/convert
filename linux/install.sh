#!/usr/bin/env bash
# Installs Convert for Linux for the current user:
#
#   ./install.sh                    into ~/.local, with the file-manager entries
#   ./install.sh --prefix /usr/local   system-wide (run with sudo), no user entries
#   ./install.sh --no-integration   the command only, no right-click entries
#
# Nothing is compiled and nothing is downloaded: the Python package is copied, and a small launcher
# script is written. Uninstall with ./uninstall.sh (same --prefix).
set -euo pipefail

# Not taken from the environment: $PREFIX is set by Termux, conda-build and
# many build shells, and would silently send the install somewhere else.
PREFIX="$HOME/.local"
PREFIX_GIVEN=0
INTEGRATION=1

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a folder}"; PREFIX_GIVEN=1; shift 2 ;;
    --prefix=*) PREFIX="${1#*=}"; PREFIX_GIVEN=1; shift ;;
    --no-integration) INTEGRATION=0; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# A system-wide install (usually under sudo) must not write right-click entries
# into whichever home directory sudo left in $HOME, as root-owned files.
if [ "$PREFIX_GIVEN" -eq 1 ] || [ "$(id -u)" -eq 0 ]; then INTEGRATION=0; fi

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
case "$PREFIX" in *'"'*) echo "install.sh: --prefix can't contain a double quote" >&2; exit 2 ;; esac
case "$PREFIX" in /*) ;; *) PREFIX="$(cd "$PREFIX" 2>/dev/null && pwd || { mkdir -p "$PREFIX" && cd "$PREFIX" && pwd; })" ;; esac

SHARE="$PREFIX/share/convert"
# NOT `convert`: on Linux that name belongs to ImageMagick (Debian, Ubuntu,
# Fedora, Arch and openSUSE all ship it), and a converter that shadows it
# breaks every script that calls `convert in.png out.jpg`. The suffix is also
# what the old hand-written helper was called, so nothing to relearn.
BIN="$PREFIX/bin/convert-file"
APPS="$PREFIX/share/applications"
ICONS="$PREFIX/share/icons/hicolor/256x256/apps"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"

say() { printf '%s\n' "$1"; }

# ── The program ──────────────────────────────────────────────────────────
mkdir -p "$SHARE" "$PREFIX/bin"

# Replace the previous copy rather than merging into it: a module removed in a
# new version must not stay behind.
rm -rf "$SHARE/convert"
cp -R "$HERE/src/convert" "$SHARE/convert"
find "$SHARE/convert" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

cat > "$BIN" <<LAUNCHER
#!/usr/bin/env python3
"""Convert for Linux -- installed by linux/install.sh."""
import sys

sys.path.insert(0, "$SHARE")
sys.dont_write_bytecode = True

from convert.cli import main  # noqa: E402

sys.exit(main())
LAUNCHER
chmod 755 "$BIN"
say "installed $BIN"

# ── The application menu entry ───────────────────────────────────────────
mkdir -p "$APPS"
printf '%s\n' \
  '[Desktop Entry]' \
  'Type=Application' \
  'Name=Convert' \
  'GenericName=File Converter' \
  'Comment=Convert files without uploading them' \
  "Exec=\"$BIN\" --ui %F" \
  'Icon=convert' \
  'Terminal=false' \
  'Categories=Utility;FileTools;' \
  'Keywords=convert;transcode;compress;pdf;image;audio;video;' \
  'StartupNotify=false' \
  'MimeType=image/*;audio/*;video/*;font/*;text/*;application/pdf;application/rtf;application/msword;application/vnd.openxmlformats-officedocument.wordprocessingml.document;application/vnd.oasis.opendocument.text;application/x-font-ttf;application/x-font-otf;application/x-font-woff;' \
  > "$APPS/convert.desktop"
chmod 644 "$APPS/convert.desktop"

if [ -f "$REPO/docs/icon.png" ]; then
  mkdir -p "$ICONS"
  cp "$REPO/docs/icon.png" "$ICONS/convert.png"
fi

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APPS" >/dev/null 2>&1 || true
fi
say "installed the menu entry"

# ── The right-click entries ──────────────────────────────────────────────
if [ "$INTEGRATION" -eq 1 ]; then
  escaped=$(printf '%s' "$BIN" | sed 's/\\/\\\\/g; s/"/\\"/g')

  install_script() {
    mkdir -p "$1"
    sed "s|__CONVERT__|$escaped|g" "$HERE/integration/nautilus-convert.py" > "$1/Convert…"
    chmod 755 "$1/Convert…"
    say "installed the right-click entry for $2"
  }

  [ -d "$DATA/nautilus" ] && install_script "$DATA/nautilus/scripts" "Nautilus / Files"
  [ -d "$DATA/nemo" ] && install_script "$DATA/nemo/scripts" "Nemo"
  [ -d "$HOME/.config/caja" ] && install_script "$HOME/.config/caja/scripts" "Caja"

  if [ -d "$DATA/kio/servicemenus" ] || [ -d "$DATA/kservices5" ] \
     || printf '%s' "${XDG_CURRENT_DESKTOP:-}" | grep -qi kde; then
    menus="$DATA/kio/servicemenus"
    [ -d "$DATA/kio" ] || menus="$DATA/kservices5/ServiceMenus"
    mkdir -p "$menus"
    sed "s|__CONVERT__|$escaped|g" "$HERE/integration/convert-servicemenu.desktop" > "$menus/convert.desktop"
    chmod 644 "$menus/convert.desktop"
    say "installed the right-click entry for Dolphin / Konqueror"
  fi

  if [ -d "$DATA/nautilus" ] || [ -d "$DATA/nemo" ] || [ -d "$DATA/kio" ]; then
    : # at least one was installed
  else
    say "no file manager with a supported scripts/actions menu was found; use \"convert-file --ui FILE\" instead"
  fi
fi

# ── What's needed ────────────────────────────────────────────────────────
echo
missing=""
command -v ffmpeg >/dev/null 2>&1 || missing="$missing ffmpeg"
{ command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1; } || missing="$missing imagemagick"
command -v pdftoppm >/dev/null 2>&1 || missing="$missing poppler-utils"
command -v rsvg-convert >/dev/null 2>&1 || missing="$missing librsvg2-bin(for SVG)"
if [ -n "$missing" ]; then
  say "not installed:$missing"
  say "Convert hides the formats that need them; install them whenever you like."
fi
  python3 -c 'import fontTools' 2>/dev/null || say "fontTools is not installed (only needed for fonts): python3 -m pip install --user fonttools brotli"
echo
say "done. Run: convert-file --list-targets"
case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) say "note: $PREFIX/bin is not in your PATH; add it with: export PATH=\"$PREFIX/bin:\$PATH\"" ;;
esac
