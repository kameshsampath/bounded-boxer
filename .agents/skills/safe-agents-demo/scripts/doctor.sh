#!/usr/bin/env bash
# =============================================================================
# Safe Agents Demo - Cross-OS Prerequisite Doctor (`scripts/doctor.sh`)
#
# Non-destructively inspects all required and optional tools for
# `bounded-boxer` (Go ADK + Labstack Echo) across Windows 11 (Ubuntu WSL2)
# and macOS (arm64). Outputs a structured status checklist and exact remediation commands.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "${SCRIPT_DIR}/../../../.." && pwd -P)"
cd "${REPO_ROOT}"

export PATH="${HOME}/.local/bin:${HOME}/.local/share/mise/shims:/usr/local/go/bin:${PATH}"

OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"
MODEL_NAME="${MODEL_NAME:-llama3.2:3b}"
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
AUDITOR_PORT="${AUDITOR_PORT:-8501}"
EXFIL_PORT="${EXFIL_PORT:-8080}"
EXFIL_SINK_PORT="${EXFIL_SINK_PORT:-9090}"

OK_COUNT=0
WARN_COUNT=0
MISSING_COUNT=0
REMEDIATIONS=()

ok() {
    echo -e "  \033[1;32m[OK]\033[0m      $1"
    OK_COUNT=$((OK_COUNT + 1))
}

warn() {
    echo -e "  \033[1;33m[WARN]\033[0m    $1"
    WARN_COUNT=$((WARN_COUNT + 1))
    if [[ -n "${2:-}" ]]; then
        REMEDIATIONS+=("$2")
    fi
}

missing() {
    echo -e "  \033[1;31m[MISSING]\033[0m $1"
    MISSING_COUNT=$((MISSING_COUNT + 1))
    if [[ -n "${2:-}" ]]; then
        REMEDIATIONS+=("$2")
    fi
}

echo -e "\033[1;36m========================================================================\033[0m"
echo -e "\033[1;36m  SAFE AGENTS DEMO - ENVIRONMENT & PREREQUISITE DOCTOR (GO EDITION)     \033[0m"
echo -e "\033[1;36m========================================================================\033[0m"

# 1. Host OS & Memory
echo -e "\n\033[1;37m1. Host Platform & Memory Boundary\033[0m"
if [[ "${OS_NAME}" == "Linux" ]]; then
    TOTAL_MEM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
    AVAIL_MEM_MB="$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)"
    if grep -qi microsoft /proc/version 2>/dev/null; then
        ok "Platform: Ubuntu WSL2 (${ARCH_NAME}) | Total RAM: ${TOTAL_MEM_MB} MB | Available: ${AVAIL_MEM_MB} MB"
    else
        ok "Platform: Native Linux (${ARCH_NAME}) | Total RAM: ${TOTAL_MEM_MB} MB | Available: ${AVAIL_MEM_MB} MB"
    fi
elif [[ "${OS_NAME}" == "Darwin" ]]; then
    TOTAL_MEM_GB="$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))"
    ok "Platform: macOS (${ARCH_NAME}) | Unified Memory: ${TOTAL_MEM_GB} GB"
fi

# 2. Sandbox Engine (bwrap on Linux/WSL2, Docker Desktop on macOS, + optional OpenShell CLI)
echo -e "\n\033[1;37m2. Runtime Sandbox Engine\033[0m"
if [[ "${OS_NAME}" == "Darwin" ]]; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        ok "Docker Desktop for Mac is running ($(docker --version | head -n1))"
        if docker image inspect bounded-boxer-ubuntu:latest >/dev/null 2>&1; then
            ok "Offline Ubuntu sandbox image ('bounded-boxer-ubuntu:latest') is built"
        else
            warn "Sandbox container image 'bounded-boxer-ubuntu:latest' not built yet" \
                 "Build macOS sandbox image: bash scripts/sandbox.sh build"
        fi
    else
        missing "Docker Desktop for Mac is not running" \
                "Start Docker Desktop.app on macOS, then run: bash scripts/provision-mac.sh"
    fi
else
    if command -v bwrap >/dev/null 2>&1; then
        ok "Linux Kernel Bubblewrap ($(bwrap --version)) installed (0 MB idle RAM)"
    else
        missing "Bubblewrap (bwrap) is not installed" \
                "Install Bubblewrap in WSL2: sudo apt-get update && sudo apt-get install -y bubblewrap"
    fi
fi

if command -v openshell >/dev/null 2>&1; then
    ok "NVIDIA OpenShell CLI installed ($(openshell --version 2>/dev/null || echo 'detected'))"
else
    echo -e "  \033[0;36m[INFO]\033[0m    NVIDIA OpenShell CLI binary not in PATH (using built-in kernel/policy enforcer in scripts/sandbox.sh)"
fi

# 3. Environment & Task Runner (mise + Go 1.24+)
echo -e "\n\033[1;37m3. Environment & Task Runner (mise & Go)\033[0m"
if command -v mise >/dev/null 2>&1; then
    ok "mise installed ($(mise --version | head -n1))"
else
    warn "mise runtime manager not found in PATH" \
         "Install mise: curl https://mise.run | sh"
fi

if command -v go >/dev/null 2>&1; then
    ok "Go toolchain installed ($(go version) @ $(command -v go))"
else
    missing "go not found" "Install Go 1.24: mise install go@1.24"
fi

# 4. Compiled Go Binaries & Vendored Sources
echo -e "\n\033[1;37m4. Compiled Go Binaries & Vendored Sources\033[0m"
if [[ -x "${REPO_ROOT}/bin/bounded-boxer-agent" && -x "${REPO_ROOT}/bin/bounded-boxer-auditor" ]]; then
    ok "Compiled Go binaries exist (bin/bounded-boxer-agent, bin/bounded-boxer-auditor)"
else
    missing "Compiled Go binaries missing in ./bin" \
            "Compile Go binaries: mise run build"
fi

if [[ -f "${REPO_ROOT}/vendor/modules.txt" ]]; then
    MOD_COUNT="$(grep -c '^# ' "${REPO_ROOT}/vendor/modules.txt" 2>/dev/null || echo 0)"
    ok "Vendored Go dependencies present (${MOD_COUNT} modules in ./vendor)"
else
    warn "Go vendor directory is missing" \
         "Vendor Go modules: mise run vendor"
fi

# 5. Local LLM Inference (Ollama + Model Cache)
echo -e "\n\033[1;37m5. Local LLM Inference (Ollama & ${MODEL_NAME})\033[0m"
if command -v ollama >/dev/null 2>&1; then
    ok "Ollama CLI installed ($(ollama --version 2>/dev/null || echo 'installed'))"
    if curl -sf "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
        ok "Ollama daemon is listening at ${OLLAMA_HOST}"
        if curl -sf "${OLLAMA_HOST}/api/tags" | grep -q "${MODEL_NAME%%:*}"; then
            ok "Model '${MODEL_NAME}' is cached locally for offline inference"
        else
            missing "Model '${MODEL_NAME}' is not pulled yet" \
                    "Pull model: ollama pull ${MODEL_NAME}"
        fi
    else
        missing "Ollama daemon is not running on ${OLLAMA_HOST}" \
                "Start Ollama daemon: nohup ollama serve >/tmp/ollama.log 2>&1 &"
    fi
else
    if [[ "${OS_NAME}" == "Darwin" ]]; then
        missing "Ollama is not installed" "Install Ollama on macOS: brew install ollama && ollama serve & sleep 2 && ollama pull ${MODEL_NAME}"
    else
        missing "Ollama is not installed in WSL2" "Install Ollama in WSL2: curl -fsSL https://ollama.com/install.sh | sh && nohup ollama serve >/tmp/ollama.log 2>&1 & sleep 2 && ollama pull ${MODEL_NAME}"
    fi
fi

# 6. Labstack Echo Visual Security Auditor (:8501 UI + :8080 Report + :9090 Exfil)
echo -e "\n\033[1;37m6. Labstack Echo Visual Security Auditor & Workspace Files\033[0m"
if [[ -s "${REPO_ROOT}/workspace/config/app-settings.yaml" && -s "${REPO_ROOT}/workspace/secrets/gcp-sa-key.json" && -s "${REPO_ROOT}/2-governed/policy.yaml" ]]; then
    ok "Workspace files (config/app-settings.yaml, secrets/gcp-sa-key.json) & 2-governed/policy.yaml verified"
else
    missing "Workspace or policy files missing" "Check git status: git checkout -- workspace/ 2-governed/policy.yaml"
fi

if curl -sf "http://127.0.0.1:${AUDITOR_PORT}/_stcore/health" >/dev/null 2>&1 && curl -sf "http://127.0.0.1:${EXFIL_PORT}/health" >/dev/null 2>&1; then
    ok "Labstack Echo Visual Security Auditor is LIVE at http://localhost:${AUDITOR_PORT} (:8080 Report + :${EXFIL_SINK_PORT} Exfil)"
else
    warn "Labstack Echo Visual Security Auditor is not running yet" \
         "Start Visual Auditor: bash scripts/auditor.sh start"
fi

# Summary & Remediation Plan
echo -e "\n\033[1;36m========================================================================\033[0m"
if (( MISSING_COUNT == 0 )); then
    echo -e "\033[1;32m  [READY] DOCTOR SUMMARY: ${OK_COUNT} OK, ${WARN_COUNT} Warnings, 0 Missing - Environment Ready!\033[0m"
else
    echo -e "\033[1;33m  [ACTION NEEDED] DOCTOR SUMMARY: ${OK_COUNT} OK, ${WARN_COUNT} Warnings, ${MISSING_COUNT} Missing Action Items\033[0m"
fi
echo -e "\033[1;36m========================================================================\033[0m"

if (( ${#REMEDIATIONS[@]} > 0 )); then
    echo -e "\n\033[1;37mRecommended Next Actions:\033[0m"
    idx=1
    for rem in "${REMEDIATIONS[@]}"; do
        echo -e "  ${idx}. ${rem}"
        idx=$((idx + 1))
    done
fi

exit 0
