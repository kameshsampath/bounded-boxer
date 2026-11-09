#!/usr/bin/env bash
# =============================================================================
# Destroy the isolated 'BoundedBoxer' WSL2 instance (Windows 11 host only).
#
# Runs the correct Windows-side sequence via WSL interop, so it works both from
# a Windows PowerShell prompt AND from inside another WSL2 distro (e.g. Ubuntu):
#     wsl.exe --terminate BoundedBoxer
#     wsl.exe --unregister BoundedBoxer
#
# Note: `wsl unregister BoundedBoxer` (no dashes) does NOT unregister anything —
# wsl.exe treats the bare word as a Linux command to run inside the default
# distro ("/bin/bash: line 1: unregister: command not found").
#
# The instance is disposable: restore it any time from the golden tarball with
#     powershell -ExecutionPolicy Bypass -File .\scripts\provision.ps1 -ResetFromGoldenTar
#
# Usage:
#   bash scripts/wsl-destroy.sh                      # destroys 'BoundedBoxer'
#   BOUNDED_BOXER_DISTRO=MyDistro bash scripts/wsl-destroy.sh
# =============================================================================
set -euo pipefail

DISTRO="${BOUNDED_BOXER_DISTRO:-BoundedBoxer}"
BASE_DISTRO="${BOUNDED_BOXER_BASE_DISTRO:-Ubuntu}"

# Guard: never unregister the distro this shell is currently running in
# (WSL2 sets WSL_DISTRO_NAME); doing so would kill the session mid-task.
if [[ "${WSL_DISTRO_NAME:-}" == "$DISTRO" ]]; then
    echo "[ERROR] You are running inside WSL2 distro '$DISTRO' itself; unregistering it would kill this shell." >&2
    echo "        From Windows PowerShell run instead:  wsl.exe --terminate $DISTRO; wsl.exe --unregister $DISTRO" >&2
    exit 1
fi

# Guard: mirror provision.ps1 — never unregister the base distro.
if [[ "$DISTRO" == "$BASE_DISTRO" ]]; then
    echo "[ERROR] Refusing to unregister base distro '$BASE_DISTRO'. Use a dedicated instance name (e.g. 'BoundedBoxer')." >&2
    exit 1
fi

# Resolve wsl.exe (interop from inside WSL2, or native when run from Windows Git Bash).
WSL_EXE="$(command -v wsl.exe 2>/dev/null || true)"
if [[ -z "${WSL_EXE}" && -x /mnt/c/Windows/System32/wsl.exe ]]; then
    WSL_EXE=/mnt/c/Windows/System32/wsl.exe
fi
if [[ -z "${WSL_EXE}" ]]; then
    echo "[ERROR] wsl.exe not found — this task only works on Windows 11 with WSL2." >&2
    echo "        From Windows PowerShell run:  wsl.exe --terminate $DISTRO; wsl.exe --unregister $DISTRO" >&2
    exit 1
fi

# Idempotent: nothing to do if the distro is not registered.
if ! "$WSL_EXE" --list --quiet 2>/dev/null | tr -d '\0\r' | grep -qx "$DISTRO"; then
    echo "---> WSL2 instance '$DISTRO' is not registered; nothing to destroy."
    exit 0
fi

echo "---> Terminating WSL2 instance '$DISTRO'..."
"$WSL_EXE" --terminate "$DISTRO" 2>/dev/null || true
echo "---> Unregistering WSL2 instance '$DISTRO' (deletes its VHD under %LOCALAPPDATA%\\WSL\\$DISTRO)..."
"$WSL_EXE" --unregister "$DISTRO"

echo "[OK] WSL2 instance '$DISTRO' destroyed."
echo "     Restore from golden tarball: powershell -ExecutionPolicy Bypass -File .\\scripts\\provision.ps1 -ResetFromGoldenTar"
