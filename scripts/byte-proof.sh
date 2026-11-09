#!/usr/bin/env bash
# =============================================================================
# Byte-proof (`scripts/byte-proof.sh`): the one-screen wow moment.
# Prints the canary secret's size OUTSIDE the sandbox vs INSIDE the governed
# sandbox. Inside, bwrap bind-mounts /dev/null over the file, so it stats as
# 0 bytes (on nodev mounts like /mnt/d, opening it is denied outright).
# Same file, same command, different boundary.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KEY_REL="workspace/secrets/gcp-sa-key.json"
KEY="${REPO_ROOT}/${KEY_REL}"

if [[ ! -s "${KEY}" ]]; then
    echo "[ERROR] Canary secret not found or empty: ${KEY}" >&2
    exit 1
fi

outside_bytes="$(stat -c %s "${KEY}")"

bash "${REPO_ROOT}/scripts/sandbox.sh" create >/dev/null
inside_bytes="$(bash "${REPO_ROOT}/scripts/sandbox.sh" exec -- stat -c %s "${KEY}" | tr -d ' ')"
inside_read="$(bash "${REPO_ROOT}/scripts/sandbox.sh" exec -- sh -c "cat '${KEY}' 2>/dev/null | wc -c" | tr -d ' ')"

echo "================================================================"
echo "  BYTE-PROOF: ${KEY_REL}"
echo "================================================================"
printf "  Outside sandbox : %6s bytes  (fully readable)\n" "${outside_bytes}"
printf "  Inside sandbox  : %6s bytes  (masked: /dev/null overmounted)\n" "${inside_bytes}"
printf "  Bytes readable inside via cat: %s\n" "${inside_read}"
echo "================================================================"

if [[ "${inside_bytes}" == "0" && "${inside_read}" == "0" && "${outside_bytes}" != "0" ]]; then
    echo "  RESULT: PASS. Same file, same command. 0 bytes inside the boundary."
    exit 0
else
    echo "  RESULT: FAIL. Expected 0 bytes inside the sandbox." >&2
    exit 1
fi
