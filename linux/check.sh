#!/usr/bin/env bash
# Runs the same checks as CI (.github/workflows/linux.yml).
#
#   ./check.sh                  syntax check, unit tests, then the smoke test
#   ./check.sh unit             syntax check and unit tests only
#   ./check.sh smoke [options]  the smoke test (see ./smoke-test.sh --help)
#
# Works from any folder.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
PYTHON=${PYTHON:-python3}
STEP="${1:-all}"
[ $# -gt 0 ] && shift

status=0

say() {
  printf '\n==> %s\n' "$1"
}

syntax() {
  say "Syntax check"
  if "$PYTHON" -m compileall -q "$ROOT/src/convert"; then
    echo "ok"
  else
    echo "syntax errors" >&2
    status=1
  fi
}

unit() {
  say "Unit tests"
  if ! "$PYTHON" -m unittest discover -s "$ROOT/tests" -v; then
    status=1
  fi
}

smoke() {
  say "Smoke test"
  if ! "$ROOT/smoke-test.sh" "$@"; then
    status=1
  fi
}

case "$STEP" in
  all) syntax; unit; smoke "$@" ;;
  unit) syntax; unit ;;
  smoke) smoke "$@" ;;
  -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown step: $STEP (all, unit, smoke)" >&2; exit 2 ;;
esac

exit "$status"
