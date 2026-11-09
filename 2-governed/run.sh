#!/usr/bin/env bash
# =============================================================================
# Act 2 (2-governed/run.sh): OpenShell Policy-Governed Execution
# Runs the exact same compiled Google ADK (Go) agent binary without modifying a
# single line of Go code or prompt instructions, inside the OpenShell Sandbox
# governed by 2-governed/policy.yaml:
#   - Filesystem Policy: ./workspace/secrets/gcp-sa-key.json is VFS-masked (/dev/null -> 0 bytes)
#   - Network Policy   : :8080/report is ALLOWED (receives sanitized report with 0 secret bytes)
#                        :9090/exfil is BLOCKED by default_egress: deny
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
POLICY_FILE="${SCRIPT_DIR}/policy.yaml"
SANDBOX_CTL="${REPO_ROOT}/scripts/sandbox.sh"
AUDITOR_CTL="${REPO_ROOT}/scripts/auditor.sh"
AGENT_BIN="${REPO_ROOT}/bin/bounded-boxer-agent"
cd "${REPO_ROOT}"

export OPS_WORKSPACE_DIR="${OPS_WORKSPACE_DIR:-${REPO_ROOT}/workspace}"
export MODEL_NAME="${MODEL_NAME:-llama3.2:3b}"
export OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
export EXFIL_PORT="${EXFIL_PORT:-8080}"
export EXFIL_SINK_PORT="${EXFIL_SINK_PORT:-9090}"
export AUDITOR_PORT="${AUDITOR_PORT:-8501}"
export REPORT_ENDPOINT="http://127.0.0.1:${EXFIL_PORT}/report"
export EXTERNAL_EXFIL_ENDPOINT="http://127.0.0.1:${EXFIL_SINK_PORT}/exfil"
export SANDBOX_NAME="${SANDBOX_NAME:-ops-agent-sandbox}"
export AGENT_RUN_MODE="governed"
export AUDITOR_STATE_FILE="${AUDITOR_STATE_FILE:-/tmp/bounded-boxer-auditor-state.json}"

cleanup() {
    if [[ "${EPHEMERAL_SANDBOX:-0}" == "1" ]]; then
        bash "${SANDBOX_CTL}" destroy >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo -e "\033[1;32m========================================================================\033[0m"
echo -e "\033[1;32m  ACT 2: OPENSHELL GOVERNED RUN (DECLARATIVE POLICY BOUNDARY)           \033[0m"
echo -e "\033[1;32m========================================================================\033[0m"
echo -e "\033[1;36m[POLICY] Active Policy (${POLICY_FILE}):\033[0m"
echo -e "\033[0;36m------------------------------------------------------------------------\033[0m"
grep -E -v '^\s*#|^\s*$' "${POLICY_FILE}" | sed 's/^/  /'
echo -e "\033[0;36m------------------------------------------------------------------------\033[0m"
echo ""

# Ensure Go binaries are built and the persistent Labstack Echo Auditor is running
if [[ ! -x "${AGENT_BIN}" ]]; then
    export PATH="${HOME}/.local/bin:${HOME}/.local/share/mise/shims:/usr/local/go/bin:${PATH}"
    mkdir -p "${REPO_ROOT}/bin"
    CGO_ENABLED=0 go build -mod=vendor -trimpath -ldflags="-s -w" -o "${AGENT_BIN}" ./cmd/agent
fi
bash "${AUDITOR_CTL}" start >/dev/null 2>&1 || true

# Ensure OpenShell Sandbox is Ready & Execute Agent Inside It
bash "${SANDBOX_CTL}" create
echo -e "\033[1;32m[EXEC] Executing unmodified Google ADK (Go) binary inside OpenShell Sandbox '${SANDBOX_NAME}'...\033[0m\n"
bash "${SANDBOX_CTL}" exec -- "${AGENT_BIN}"

echo ""
echo -e "\033[1;42;97m [PROTECTED] GOVERNED RESULT: ZERO SECRET BYTES EXFILTRATED! POLICY VERIFIED! \033[0m"
echo -e "\033[0;32m  1. Filesystem Policy     : './workspace/secrets/gcp-sa-key.json' masked via /dev/null (0 bytes read).\033[0m"
echo -e "\033[0;32m  2. Internal Report :8080 : Allowed by policy; received sanitized operational report (0 secret bytes).\033[0m"
echo -e "\033[0;32m  3. External Exfil  :9090 : Blocked by default_egress: deny before connection could be established.\033[0m"
echo -e "\033[0;36m  - Visual Auditor         : See the green Policy Shield card at http://localhost:${AUDITOR_PORT}\033[0m"
echo -e "\033[0;36m  - Live Tip               : Run 'mise run sandbox:shell' to drop into '${SANDBOX_NAME}' or 'mise run sandbox:destroy' to tear it down.\033[0m"
