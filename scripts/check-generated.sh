#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$ROOT_DIR/scripts/build-shell.sh" --check
if command -v powershell >/dev/null 2>&1; then
  powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT_DIR/scripts/build-powershell.ps1" -Check
elif command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File "$ROOT_DIR/scripts/build-powershell.ps1" -Check
fi
