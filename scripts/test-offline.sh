#!/usr/bin/env bash
# =============================================================================
# Pre-Flight Offline Verification (`scripts/test-offline.sh`)
# Validates that the laptop (Windows 11 WSL2 OR Apple Silicon Mac) is 100% ready
# for zero-Wi-Fi keynote execution:
#   1. Host OS & Memory Boundary (~8GB WSL2 cap on Windows or 16GB Unified Memory on Mac)
#   2. Sandbox Engine (Zero-daemon `bwrap` on Linux/WSL2 OR Docker Desktop on macOS)
#   3. Go Toolchain, Compiled Static Binaries (`bin/`), & Offline `vendor/` Cache
#   4. Local Ollama server health + cached model weights + RAM warm-up (keep_alive=-1)
#   5. Workspace canary files (`config/app-settings.yaml`, `secrets/gcp-sa-key.json`)
#   6. Persistent Labstack Echo Visual Auditor (`:8501` UI, `:8080` Report, `:9090` Exfil) & Governed Smoke Test
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

export PATH="${HOME}/.local/bin:${HOME}/.local/share/mise/shims:/usr/local/go/bin:${PATH}"

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
echo -e "\033[1;36m  PRE-FLIGHT OFFLINE VERIFICATION: bounded-boxer (Go ADK + Echo)        \033[0m"
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
        pass "WSL2 RAM capped at ${TOTAL_MEM_MB} MB (Currently used: ${USED_MEM_MB} MB - plenty of headroom)"
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
        if docker image inspect bounded-boxer-ubuntu:latest >/dev/null 2>&1; then
            pass "Sandbox image 'bounded-boxer-ubuntu:latest' is cached locally"
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
# Check 3: Go Binaries & Vendored Sources
# ---------------------------------------------------------------------------
echo -e "\n\033[1;37m[3/6] Checking Go Binaries & Vendored Sources...\033[0m"
if [[ ! -x "${REPO_ROOT}/bin/bounded-boxer-agent" || ! -x "${REPO_ROOT}/bin/bounded-boxer-auditor" ]]; then
    mkdir -p "${REPO_ROOT}/bin"
    CGO_ENABLED=0 go build -mod=vendor -trimpath -ldflags="-s -w" -o "${REPO_ROOT}/bin/bounded-boxer-agent" ./cmd/agent
    CGO_ENABLED=0 go build -mod=vendor -trimpath -ldflags="-s -w" -o "${REPO_ROOT}/bin/bounded-boxer-auditor" ./cmd/auditor
fi

if [[ -x "${REPO_ROOT}/bin/bounded-boxer-agent" && -x "${REPO_ROOT}/bin/bounded-boxer-auditor" ]]; then
    pass "Compiled Go binaries verified (bin/bounded-boxer-agent, bin/bounded-boxer-auditor)"
else
    fail "Go binaries missing. Run: mise run build"
fi

if [[ -f "${REPO_ROOT}/vendor/modules.txt" ]]; then
    MOD_COUNT="$(grep -c '^# ' "${REPO_ROOT}/vendor/modules.txt" 2>/dev/null || echo 0)"
    pass "Vendored Go dependencies present (${MOD_COUNT} modules in ./vendor)"
else
    warn "Go vendor directory missing (run 'mise run vendor')"
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
# Check 6: Start Labstack Echo Visual Auditor & Smoke-Test Governed Policy
# ---------------------------------------------------------------------------
echo -e "\n\033[1;37m[6/6] Starting Labstack Echo Visual Auditor (:8501) & Smoke-Testing 2-governed/policy.yaml...\033[0m"
bash "${REPO_ROOT}/scripts/auditor.sh" start >/dev/null 2>&1 || true
if curl -sf "http://127.0.0.1:8501/_stcore/health" >/dev/null 2>&1; then
    pass "Labstack Echo Visual Security Auditor live at http://localhost:8501 (:8080 Report + :9090 Exfil)"
else
    warn "Visual Auditor not responding on :8501 (run 'mise run auditor:start')"
fi

PREFLIGHT_LOG="$(mktemp /tmp/preflight-governed-XXXXXX.log)"
if bash "${REPO_ROOT}/2-governed/run.sh" >"${PREFLIGHT_LOG}" 2>&1; then
    if grep -q "ZERO SECRET BYTES EXFILTRATED" "${PREFLIGHT_LOG}"; then
        pass "OpenShell governed run verified: GCP SA key masked, sanitized :8080 report delivered, :9090 exfil blocked!"
        rm -f "${PREFLIGHT_LOG}"
    else
        fail "2-governed/run.sh completed but did not report expected policy verification. Check ${PREFLIGHT_LOG}"
    fi
else
    cat "${PREFLIGHT_LOG}"
    fail "2-governed/run.sh exited with non-zero code during pre-flight test (log: ${PREFLIGHT_LOG})"
fi
bash "${REPO_ROOT}/scripts/auditor.sh" clear >/dev/null 2>&1 || true

echo -e "\n\033[1;42;97m [READY] PRE-FLIGHT PASSED (${PASS_COUNT} checks passed, ${WARN_COUNT} warnings) - READY FOR STAGE! \033[0m"
echo -e "  - \033[1;36mOpen Visual Security Auditor in Browser:\033[0m \033[1;4;32mhttp://localhost:8501\033[0m"
