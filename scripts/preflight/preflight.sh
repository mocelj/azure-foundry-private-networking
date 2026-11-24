#!/usr/bin/env sh
# POSIX wrapper for the preprovision hook. The preflight logic lives in preflight.ps1 so that a
# single implementation is tested; PowerShell 7 (pwsh) is available on GitHub-hosted runners,
# Azure Cloud Shell and via https://aka.ms/install-powershell.
set -e
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if ! command -v pwsh >/dev/null 2>&1; then
  echo "[FAIL] pwsh (PowerShell 7+) is required for preflight checks. Install: https://aka.ms/install-powershell" >&2
  exit 1
fi
exec pwsh -NoProfile -File "$SCRIPT_DIR/preflight.ps1" "$@"
