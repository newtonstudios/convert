#!/usr/bin/env bash
# Removes what install.sh installed. Files you converted are not touched.
#
#   ./uninstall.sh                  from ~/.local
#   ./uninstall.sh --prefix /usr/local
set -euo pipefail

PREFIX="$HOME/.local"
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a folder}"; shift 2 ;;
    --prefix=*) PREFIX="${1#*=}"; shift ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

SHARE="$PREFIX/share/convert"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
removed=0

remove() {
  if [ -e "$1" ]; then
    rm -rf "$1"
    printf 'removed %s\n' "$1"
    removed=$((removed + 1))
  fi
}

remove "$SHARE"
remove "$PREFIX/bin/convert-file"
remove "$PREFIX/share/applications/convert.desktop"
remove "$PREFIX/share/icons/hicolor/256x256/apps/convert.png"
remove "$DATA/nautilus/scripts/Convert…"
remove "$DATA/nemo/scripts/Convert…"
remove "$HOME/.config/caja/scripts/Convert…"
remove "$DATA/kio/servicemenus/convert.desktop"
remove "$DATA/kservices5/ServiceMenus/convert.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$PREFIX/share/applications" >/dev/null 2>&1 || true
fi

if [ "$removed" -eq 0 ]; then
  echo "nothing to remove in $PREFIX"
fi
