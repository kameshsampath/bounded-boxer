#!/usr/bin/env bash
# =============================================================================
# macOS (Apple Silicon M1/M2/M3/M4, 16GB RAM) Provisioner (`scripts/provision-mac.sh`)
#
# Sets up the exact same `devfest-safe-agents-demo` environment on macOS using:
#   - Docker Desktop for Mac (builds `devfest-openshell-ubuntu:latest` for linux/arm64)
#   - Local Ollama on Apple Metal GPU (`llama3.2:3b`)
#   - `mise` + Python 3.12 virtualenv (`~/.venvs/devfest-safe-agents-demo`)
#   - Local Airgap Wheelhouse Cache (`.cache/wheelhouse/Darwin-arm64/`)
#   - Persistent Streamlit Visual Security Auditor (`http://localhost:8501`)
#
# Usage:
#   bash scripts/provision-mac.sh [llama3.2:3b]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PRIMARY_MODEL="${1:-${MODEL_NAME:-llama3.2:3b}}"
cd "${REPO_ROOT}"

echo -e "\033[1;36m========================================================================\033[0m"
echo -e "\033[1;36m  Keynote Infrastructure Prep: devfest-safe-agents-demo (macOS Arm64)   \033[0m"
echo -e "\033[1;36m  Target: Apple Silicon Mac (16GB) + Docker Desktop + Ollama + Visual UI\033[0m"
echo -e "\033[1;36m========================================================================\033[0m"

chmod +x "${REPO_ROOT}/1-baseline/run.sh" \
         "${REPO_ROOT}/2-governed/run.sh" \
         "${REPO_ROOT}/scripts/test-offline.sh" \
         "${REPO_ROOT}/scripts/sandbox.sh" \
         "${REPO_ROOT}/scripts/auditor.sh" \
         "${REPO_ROOT}/scripts/cache-deps.sh" \
         "${REPO_ROOT}/agent/agent.py"

# 1. Verify Docker Desktop for Mac
echo -e "\n\033[1;33m[1/5] Checking Docker Desktop for Mac...\033[0m"
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo -e "\033[1;31m[ERROR] Docker Desktop is not running. Please start Docker Desktop on your Mac and re-run.\033[0m"
    exit 1
fi
echo -e "  ✓ Docker Desktop is active ($(docker --version))"

# 2. Check / Install mise & Ollama
echo -e "\n\033[1;33m[2/5] Checking mise and Ollama on macOS...\033[0m"
if ! command -v mise >/dev/null 2>&1 && [[ ! -x "${HOME}/.local/bin/mise" ]]; then
    curl https://mise.run | sh
fi
export PATH="${HOME}/.local/bin:${HOME}/.local/share/mise/shims:${PATH}"

if ! command -v ollama >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        brew install ollama
    else
        echo -e "\033[1;31m[ERROR] Ollama not found. Install from https://ollama.com/download/Ollama-darwin.zip\033[0m"
        exit 1
    fi
fi

if ! curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    nohup ollama serve >/tmp/ollama-mac.log 2>&1 &
    sleep 2
fi
echo -e "  ---> Pre-pulling Ollama model (${PRIMARY_MODEL})..."
ollama pull "${PRIMARY_MODEL}"

# 3. Create Virtualenv & Populate Darwin-arm64 Airgap Wheelhouse
echo -e "\n\033[1;33m[3/5] Provisioning Python virtualenv & caching macOS wheelhouse...\033[0m"
VENV_DIR="${HOME}/.venvs/devfest-safe-agents-demo"
mkdir -p "$(dirname "${VENV_DIR}")"
python3 -m venv "${VENV_DIR}"
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip -q
bash "${REPO_ROOT}/scripts/cache-deps.sh" install

# 4. Pre-build Offline Ubuntu Sandbox Container Image in Docker Desktop
echo -e "\n\033[1;33m[4/5] Building Ubuntu OpenShell Sandbox Container in Docker Desktop...\033[0m"
bash "${REPO_ROOT}/scripts/sandbox.sh" build
bash "${REPO_ROOT}/scripts/sandbox.sh" create
bash "${REPO_ROOT}/scripts/auditor.sh" start

# 5. Run Pre-Flight Verification
echo -e "\n\033[1;33m[5/5] Running Offline Pre-Flight Verification...\033[0m"
if command -v mise >/dev/null 2>&1; then
    mise trust "${REPO_ROOT}/mise.toml" || true
fi
MODEL_NAME="${PRIMARY_MODEL}" bash "${REPO_ROOT}/scripts/test-offline.sh"
