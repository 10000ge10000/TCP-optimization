#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$ROOT_DIR/scripts/build-shell.sh" --check
if command -v powershell >/dev/null 2>&1; then
  powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT_DIR/scripts/build-powershell.ps1" -Check
elif command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File "$ROOT_DIR/scripts/build-powershell.ps1" -Check
else
  # 静默跳过会掩盖 tcp-tune.ps1 漂移，必须显式失败。
  printf '无法验证 tcp-tune.ps1：缺少 powershell/pwsh。请安装 PowerShell 后重试。\n' >&2
  exit 1
fi
