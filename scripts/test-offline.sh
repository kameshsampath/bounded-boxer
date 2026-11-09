#!/usr/bin/env bash
# =============================================================================
# Pre-Flight Offline Verification (`scripts/test-offline.sh`)
# Validates that the laptop (Windows 11 WSL2 OR Apple Silicon Mac) is 100% ready
# for zero-Wi-Fi keynote execution:
#   1. Host OS & Memory Boundary (~8GB WSL2 cap on Windows or 16GB Unified Memory on Mac)
#   2. Sandbox Engine (Zero-daemon `bwrap` on Linux/WSL2 OR Docker Desktop on macOS)
#   3. Python Virtualenv, Google ADK / LiteLLM / Streamlit imports & Airgap Wheelhouse
#   4. Local Ollama server health + cached model weights + RAM warm-up (keep_alive=-1)
#   5. Workspace canary files (`config/app-settings.yaml`, `secrets/gcp-sa-key.json`)
#   6. Persistent Streamlit Visual Auditor (`:8501` UI + `:8080` Sink) & Governed Smoke Test
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# Activate virtualenv if present
if [[ -z "${VIRTUAL_ENV:-}" && -f "${HOME}/.venvs/devfest-safe-agents-demo/bin/activate" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.venvs/devfest-safe-agents-demo/bin/activate"
fi

MODEL_NAME="${MODEL_NAME:-llama3.2:3b}"
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"

PASS_COUNT=0
WARN_COUNT=0

pass() {
    echo -e "  \033[1;32m[PASS]\033[0m $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

warn() {
    echo -e "  \033[1;33m[WARN]\033[0m $1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

fail() {
    echo -e "  \033[1;31m[FAIL]\033[0m $1"
    exit 1
}

echo -e "\033[1;36m========================================================================\033[0m"
echo -e "\033[1;36m  PRE-FLIGHT OFFLINE VERIFICATION: devfest-safe-agents-demo             \033[0m"
echo -e "\033[1;36m  Platform: ${OS_NAME} (${ARCH_NAME})                                   \033[0m"
echo -e "\033[1;36m========================================================================\033[0m"

# ---------------------------------------------------------------------------
# Check 1: Host Memory Boundary
# ---------------------------------------------------------------------------
echo -e "\n\033[1;37m[1/6] Checking Host OS & Memory Boundary...\033[0m"
if [[ "${OS_NAME}" == "Linux" ]]; then
    TOTAL_MEM_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
    TOTAL_MEM_MB="$((TOTAL_MEM_KB / 1024))"
    USED_MEM_MB="$(free -m | awk '/^Mem:/ {print $3}')"
    if (( TOTAL_MEM_MB <= 8600 )); then
        pass "WSL2 RAM capped at ${TOTAL_MEM_MB} MB (Currently used: ${USED_MEM_MB} MB — plenty of headroom)"
    else
        warn "WSL2 RAM is ${TOTAL_MEM_MB} MB (> 8GB). Run 'wsl --shutdown' after running scripts/provision.ps1"
    fi
elif [[ "${OS_NAME}" == "Darwin" ]]; then
    TOTAL_MEM_BYTES="$(sysctl -n hw.memsize)"
    TOTAL_MEM_GB="$((TOTAL_MEM_BYTES / 1024 / 1024 / 1024))"
    pass "macOS Apple Silicon Unified Memory: ${TOTAL_MEM_GB} GB"
fi

# ---------------------------------------------------------------------------
# Check 2: OS-Specific Sandbox Engine (bwrap on Linux/WSL2, Docker Desktop on macOS)
# ---------------------------------------------------------------------------
echo -e "\n\033[1;37m[2/6] Checking OpenShell Sandbox Engine...\033[0m"
if [[ "${OS_NAME}" == "Darwin" ]] || [[ "${SANDBOX_ENGINE:-}" == "docker" ]]; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        pass "Docker Desktop is active for container sandboxing"
        if docker image inspect devfest-openshell-ubuntu:latest >/dev/null 2>&1; then
            pass "Sandbox image 'devfest-openshell-ubuntu:latest' is cached locally"
        else
            warn "Sandbox image not built yet (run 'mise run sandbox:build')"
        fi
    else
        fail "Docker Desktop is not running. Start Docker Desktop on macOS."
    fi
else
    if command -v bwrap >/dev/null 2>&1; then
        pass "Linux Kernel Bubblewrap ($(bwrap --version)) installed (0 MB idle daemon overhead)"
    else
        fail "Bubblewrap (bwrap) not found. Install with: sudo apt-get install -y bubblewrap"
    fi
fi

# ---------------------------------------------------------------------------
# Check 3: Python Dependencies & Offline Airgap Wheelhouse
# ---------------------------------------------------------------------------
echo -e "\n\033[1;37m[3/6] Checking Python Dependencies & Airgap Wheelhouse Cache...\033[0m"
if python3 -c "import google.adk, litellm, requests, rich, yaml, streamlit" >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
    pass "All Python packages (ADK, LiteLLM, Streamlit) import cleanly (${PYTHON_BIN})"
else
    fail "Missing Python packages. Run: mise run install"
fi

WHEELHOUSE_DIR="${REPO_ROOT}/.cache/wheelhouse/${OS_NAME}-${ARCH_NAME}"
if [[ -d "${WHEELHOUSE_DIR}" ]] && [[ -n "$(find "${WHEELHOUSE_DIR}" -name "*.whl" -print -quit 2>/dev/null)" ]]; then
    WHEEL_COUNT="$(find "${WHEELHOUSE_DIR}" -name "*.whl" | wc -l | tr -d ' ')"
    pass "Airgap wheelhouse cached (${WHEEL_COUNT} wheels in .cache/wheelhouse/${OS_NAME}-${ARCH_NAME})"
else
    warn "Airgap wheelhouse not populated yet (run 'mise run cache:deps' while on Wi-Fi)"
fi

# ---------------------------------------------------------------------------
# Check 4: Local Ollama Server & Model Warm-Up in RAM
# ---------------------------------------------------------------------------
echo -e "\n\033[1;37m[4/6] Checking Local Ollama Inference & Pre-Warming '${MODEL_NAME}'...\033[0m"
if ! curl -sf "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
    fail "Ollama is not reachable at ${OLLAMA_HOST}. Start it with: ollama serve &"
fi
pass "Ollama API responding at ${OLLAMA_HOST}"

if curl -sf "${OLLAMA_HOST}/api/tags" | grep -q "${MODEL_NAME%%:*}"; then
    pass "Model '${MODEL_NAME}' is downloaded and available offline"
else
    fail "Model '${MODEL_NAME}' not found in local Ollama cache. Run: ollama pull ${MODEL_NAME}"
fi

if curl -sf "${OLLAMA_HOST}/api/generate" \
    -d "{\"model\": \"${MODEL_NAME}\", \"prompt\": \"ping\", \"stream\": false, \"keep_alive\": -1}" >/dev/null 2>&1; then
    pass "Model '${MODEL_NAME}' pre-warmed and pinned in RAM (keep_alive: -1)"
else
    warn "Could not pre-warm '${MODEL_NAME}' via /api/generate"
fi

# ---------------------------------------------------------------------------
# Check 5: Demo Workspace (GCP SA Key) & OpenShell Policy Files
# ---------------------------------------------------------------------------
echo -e "\n\033[1;37m[5/6] Checking Demo Workspace & OpenShell Policy Files...\033[0m"
[[ -s "${REPO_ROOT}/workspace/config/app-settings.yaml" ]] || fail "Missing workspace/config/app-settings.yaml"
[[ -s "${REPO_ROOT}/workspace/secrets/gcp-sa-key.json" ]] || fail "Missing workspace/secrets/gcp-sa-key.json"
[[ -s "${REPO_ROOT}/2-governed/policy.yaml" ]] || fail "Missing 2-governed/policy.yaml"
pass "Workspace config, canary GCP SA JSON key, and 2-governed/policy.yaml verified"

# ---------------------------------------------------------------------------
# Check 6: Start Streamlit Visual Auditor & Smoke-Test Governed Policy
# ---------------------------------------------------------------------------
echo -e "\n\033[1;37m[6/6] Starting Visual Auditor (:8501) & Smoke-Testing 2-governed/policy.yaml...\033[0m"
bash "${REPO_ROOT}/scripts/auditor.sh" start >/dev/null 2>&1 || true
if curl -sf "http://127.0.0.1:8501/_stcore/health" >/dev/null 2>&1; then
    pass "Streamlit Visual Security Auditor live at http://localhost:8501 (Sink on :8080)"
else
    warn "Streamlit Visual Auditor not responding on :8501 (run 'mise run auditor:start')"
fi

if bash "${REPO_ROOT}/2-governed/run.sh" >/tmp/preflight-governed.log 2>&1; then
    if grep -q "ZERO BYTES EXFILTRATED" /tmp/preflight-governed.log; then
        pass "OpenShell governed run verified: GCP SA key masked & egress POST blocked!"
    else
        fail "2-governed/run.sh completed but did not report expected policy block. Check /tmp/preflight-governed.log"
    fi
else
    cat /tmp/preflight-governed.log
    fail "2-governed/run.sh exited with non-zero code during pre-flight test"
fi
rm -f /tmp/preflight-governed.log
bash "${REPO_ROOT}/scripts/auditor.sh" clear >/dev/null 2>&1 || true

echo -e "\n\033[1;42;97m 🟢 PRE-FLIGHT PASSED (${PASS_COUNT} checks passed, ${WARN_COUNT} warnings) — READY FOR STAGE! \033[0m"
echo -e "  🌐 \033[1;36mOpen Visual Security Auditor in Browser:\033[0m \033[1;4;32mhttp://localhost:8501\033[0m"
