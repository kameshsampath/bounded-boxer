#!/usr/bin/env bash
# =============================================================================
# Airgap / Weak-Wi-Fi Offline Python Wheelhouse Manager (`scripts/cache-deps.sh`)
#
# Pre-downloads all Python wheels (.whl) for the current OS & CPU architecture
# into `.cache/wheelhouse/<OS>-<ARCH>/` (e.g. Linux-x86_64 or Darwin-arm64).
# When at the conference venue with weak/zero Wi-Fi, `install` automatically
# installs from the local wheelhouse cache (`--no-index --find-links`)!
#
# Usage:
#   bash scripts/cache-deps.sh download   # Download all wheels into .cache/wheelhouse
#   bash scripts/cache-deps.sh install    # Install from local wheelhouse (or online if empty)
#   bash scripts/cache-deps.sh status     # Show cached wheels count & size
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REQ_FILE="${REPO_ROOT}/agent/requirements.txt"

OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"
WHEELHOUSE_DIR="${REPO_ROOT}/.cache/wheelhouse/${OS_NAME}-${ARCH_NAME}"

# Activate virtualenv if available
if [[ -z "${VIRTUAL_ENV:-}" && -f "${HOME}/.venvs/devfest-safe-agents-demo/bin/activate" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.venvs/devfest-safe-agents-demo/bin/activate"
fi

ACTION="${1:-status}"

cmd_download() {
    mkdir -p "${WHEELHOUSE_DIR}"
    echo -e "\033[1;36m📦 Caching Python wheels for ${OS_NAME}-${ARCH_NAME} into ${WHEELHOUSE_DIR}...\033[0m"
    pip download --dest "${WHEELHOUSE_DIR}" pip setuptools wheel -q
    pip download --dest "${WHEELHOUSE_DIR}" -r "${REQ_FILE}" -q
    local count
    count="$(find "${WHEELHOUSE_DIR}" -name "*.whl" | wc -l | tr -d ' ')"
    echo -e "\033[1;32m✓ Cached ${count} wheel files in ${WHEELHOUSE_DIR} (100% Airgap Ready!).\033[0m"
}

cmd_install() {
    if [[ -d "${WHEELHOUSE_DIR}" ]] && [[ -n "$(find "${WHEELHOUSE_DIR}" -name "*.whl" -print -quit 2>/dev/null)" ]]; then
        echo -e "\033[1;32m⚡ Installing Python dependencies from local airgap wheelhouse (${WHEELHOUSE_DIR})...\033[0m"
        pip install --no-index --find-links="${WHEELHOUSE_DIR}" -r "${REQ_FILE}"
        echo -e "\033[1;32m✓ Offline installation complete (zero internet calls).\033[0m"
    else
        echo -e "\033[1;33m🌐 Local wheelhouse empty; installing from PyPI and populating cache...\033[0m"
        cmd_download
        pip install --no-index --find-links="${WHEELHOUSE_DIR}" -r "${REQ_FILE}"
    fi
}

cmd_status() {
    if [[ -d "${WHEELHOUSE_DIR}" ]]; then
        local count size
        count="$(find "${WHEELHOUSE_DIR}" -name "*.whl" | wc -l | tr -d ' ')"
        size="$(du -sh "${WHEELHOUSE_DIR}" 2>/dev/null | awk '{print $1}')"
        echo -e "  • \033[1;32mWheelhouse (${OS_NAME}-${ARCH_NAME})\033[0m : ${count} wheels cached (${size}) at ${WHEELHOUSE_DIR}"
    else
        echo -e "  • \033[1;33mWheelhouse (${OS_NAME}-${ARCH_NAME})\033[0m : Not cached yet (run 'mise run cache:deps')"
    fi
}

case "${ACTION}" in
    download|cache)
        cmd_download
        ;;
    install)
        cmd_install
        ;;
    status)
        cmd_status
        ;;
    *)
        echo "Usage: $0 {download|install|status}"
        exit 1
        ;;
esac
