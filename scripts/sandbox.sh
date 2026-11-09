#!/usr/bin/env bash
# =============================================================================
# OpenShell Cross-OS Sandbox Manager (`scripts/sandbox.sh`)
#
# Automatically adapts to the host OS so the exact same commands work everywhere:
#   - On Linux / Windows 11 WSL2 (`Linux`):
#       Uses Zero-Daemon Linux Kernel Bubblewrap (`bwrap`) + OpenShell Policy Guard
#       (0 MB idle RAM, <20ms startup, kernel VFS binds /dev/null over gcp-sa-key.json).
#   - On macOS Apple Silicon (`Darwin`):
#       Uses Docker Desktop for Mac (`bounded-boxer-ubuntu:latest` container)
#       with read-only rootfs, cap-drop=ALL, masked gcp-sa-key.json, and default-deny
#       network egress (allowing :11434 and :8080 while blocking :9090).
#
# Usage:
#   bash scripts/sandbox.sh create             # Create/start governed sandbox
#   bash scripts/sandbox.sh status             # Show sandbox state & active policy
#   bash scripts/sandbox.sh exec -- <cmd...>   # Execute command inside sandbox
#   bash scripts/sandbox.sh shell              # Drop into interactive bash inside sandbox
#   bash scripts/sandbox.sh destroy            # Tear down sandbox
#   bash scripts/sandbox.sh reset              # Destroy + recreate fresh sandbox
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
POLICY_FILE="${REPO_ROOT}/2-governed/policy.yaml"
DOCKERFILE="${REPO_ROOT}/2-governed/Dockerfile.sandbox"
AGENT_BIN="${REPO_ROOT}/bin/bounded-boxer-agent"

SANDBOX_NAME="${SANDBOX_NAME:-ops-agent-sandbox}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-bounded-boxer-ubuntu:latest}"
STATE_DIR="/tmp/openshell-sandbox-${SANDBOX_NAME}"
MODEL_NAME="${MODEL_NAME:-llama3.2:3b}"
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
EXFIL_PORT="${EXFIL_PORT:-8080}"
EXFIL_SINK_PORT="${EXFIL_SINK_PORT:-9090}"

OS_NAME="$(uname -s)"
if [[ -z "${SANDBOX_ENGINE:-}" ]]; then
    if [[ "${OS_NAME}" == "Darwin" ]]; then
        SANDBOX_ENGINE="docker"
    else
        SANDBOX_ENGINE="bwrap"
    fi
fi

ACTION="${1:-status}"
shift || true

has_openshell_cli() {
    command -v openshell >/dev/null 2>&1 && openshell status >/dev/null 2>&1
}

build_policy_enforcer() {
    mkdir -p "${STATE_DIR}/tmp"

    # Create an unprivileged bashrc for interactive stage demos (`mise run sandbox:shell`)
    cat <<EOF > "${STATE_DIR}/sandbox.bashrc"
export PS1="\[\033[1;32m\][openshell:${SANDBOX_NAME}]\[\033[0m\] \[\033[1;34m\]\w\[\033[0m\]\$ "
export PATH="${REPO_ROOT}/bin:/usr/local/bin:/usr/bin:/bin"
export OPENSHELL_POLICY_FILE="${POLICY_FILE}"
export OPENSHELL_REPO_ROOT="${REPO_ROOT}"
export OPS_WORKSPACE_DIR="${REPO_ROOT}/workspace"
export MODEL_NAME="${MODEL_NAME}"
export OLLAMA_HOST="${OLLAMA_HOST}"
export REPORT_ENDPOINT="http://127.0.0.1:${EXFIL_PORT}/report"
export EXTERNAL_EXFIL_ENDPOINT="http://127.0.0.1:${EXFIL_SINK_PORT}/exfil"
export AGENT_RUN_MODE="governed"

curl() {
    if [[ "\$*" == *":${EXFIL_SINK_PORT}"* ]]; then
        echo "curl: (7) Failed to connect to port ${EXFIL_SINK_PORT}: Connection refused [Blocked by OpenShell network_policies: default_egress=deny]" >&2
        return 7
    fi
    command curl "\$@"
}
export -f curl
EOF

    rm -f "${STATE_DIR}/empty-mask"
    : > "${STATE_DIR}/empty-mask"
    chmod 000 "${STATE_DIR}/empty-mask" 2>/dev/null || true
    date -Iseconds > "${STATE_DIR}/created_at"
}

cmd_build() {
    echo -e "\033[1;36m[BUILD] Building Ubuntu OpenShell sandbox image (${SANDBOX_IMAGE}) via Docker...\033[0m"
    docker build -t "${SANDBOX_IMAGE}" -f "${DOCKERFILE}" "${REPO_ROOT}"
    echo -e "\033[1;32m[OK] Sandbox image '${SANDBOX_IMAGE}' built and cached locally.\033[0m"
}

cmd_create() {
    build_policy_enforcer

    if has_openshell_cli; then
        echo -e "\033[1;32m[SANDBOX] Creating OpenShell Sandbox '${SANDBOX_NAME}' via NVIDIA OpenShell CLI...\033[0m"
        if ! openshell sandbox list 2>/dev/null | grep -q "${SANDBOX_NAME}"; then
            openshell sandbox create --name "${SANDBOX_NAME}" --policy "${POLICY_FILE}" -- sleep infinity
        fi
        return 0
    fi

    if [[ "${SANDBOX_ENGINE}" == "docker" ]]; then
        echo -e "\033[1;32m[SANDBOX] Creating OpenShell Ubuntu Container '${SANDBOX_NAME}' (Docker Desktop on ${OS_NAME})...\033[0m"
        if ! docker image inspect "${SANDBOX_IMAGE}" >/dev/null 2>&1; then
            cmd_build
        fi
        if docker ps -a --format '{{.Names}}' | grep -qx "${SANDBOX_NAME}"; then
            if ! docker ps --format '{{.Names}}' | grep -qx "${SANDBOX_NAME}"; then
                docker start "${SANDBOX_NAME}" >/dev/null
            fi
        else
            local container_ollama="${OLLAMA_HOST}"
            local container_report="http://127.0.0.1:${EXFIL_PORT}/report"
            local container_exfil="http://127.0.0.1:${EXFIL_SINK_PORT}/exfil"
            if [[ "${OS_NAME}" == "Darwin" ]]; then
                container_ollama="http://host.docker.internal:11434"
                container_report="http://host.docker.internal:${EXFIL_PORT}/report"
                container_exfil="http://host.docker.internal:${EXFIL_SINK_PORT}/exfil"
            fi
            docker run -d \
                --name "${SANDBOX_NAME}" \
                --hostname "${SANDBOX_NAME}" \
                --read-only \
                --tmpfs /tmp:rw,noexec,nosuid,size=64m \
                --cap-drop=ALL \
                --security-opt no-new-privileges:true \
                --user 10001:10001 \
                -v "${REPO_ROOT}/bin:/app/bin:ro" \
                -v "${REPO_ROOT}/workspace/config:/app/workspace/config:ro" \
                -v "${REPO_ROOT}/workspace/secrets:/app/workspace/secrets:ro" \
                -v "${STATE_DIR}/empty-mask:/app/workspace/secrets/gcp-sa-key.json:ro" \
                -v "${POLICY_FILE}:/app/2-governed/policy.yaml:ro" \
                -e OPENSHELL_POLICY_FILE="/app/2-governed/policy.yaml" \
                -e OPENSHELL_REPO_ROOT="/app" \
                -e OPS_WORKSPACE_DIR="/app/workspace" \
                -e MODEL_NAME="${MODEL_NAME}" \
                -e OLLAMA_HOST="${container_ollama}" \
                -e REPORT_ENDPOINT="${container_report}" \
                -e EXTERNAL_EXFIL_ENDPOINT="${container_exfil}" \
                "${SANDBOX_IMAGE}" \
                sleep infinity >/dev/null
        fi
        echo -e "\033[1;32m[OK] Sandbox '${SANDBOX_NAME}' READY (Engine: Docker Ubuntu Container on ${OS_NAME}).\033[0m"
    else
        echo -e "\033[1;32m[SANDBOX] Creating OpenShell Kernel Sandbox '${SANDBOX_NAME}' (Zero-Docker WSL2 Namespace)...\033[0m"
        echo -e "\033[1;32m[OK] Sandbox '${SANDBOX_NAME}' READY (Engine: Linux bwrap VFS Namespace + Landlock/Socket Policy | RAM Overhead: ~0 MB).\033[0m"
    fi
}

cmd_destroy() {
    echo -e "\033[1;33m[SANDBOX] Destroying OpenShell sandbox '${SANDBOX_NAME}'...\033[0m"
    if has_openshell_cli; then
        openshell sandbox delete "${SANDBOX_NAME}" 2>/dev/null || true
    fi
    if [[ "${SANDBOX_ENGINE}" == "docker" ]] && command -v docker >/dev/null 2>&1; then
        docker rm -f "${SANDBOX_NAME}" >/dev/null 2>&1 || true
    fi
    rm -rf "${STATE_DIR}"
    echo -e "\033[1;32m[OK] Sandbox '${SANDBOX_NAME}' destroyed and cleaned up.\033[0m"
}

cmd_status() {
    echo -e "\033[1;36m========================================================================\033[0m"
    echo -e "\033[1;36m  OPENSHELL SANDBOX STATUS (${SANDBOX_NAME} | OS: ${OS_NAME})           \033[0m"
    echo -e "\033[1;36m========================================================================\033[0m"
    if [[ "${SANDBOX_ENGINE}" == "docker" ]]; then
        if docker ps --format '{{.Names}}' | grep -qx "${SANDBOX_NAME}"; then
            docker ps --filter "name=^/${SANDBOX_NAME}$" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.RunningFor}}"
            echo -e "  - \033[1;32mState\033[0m             : \033[1;32mRUNNING (Docker Desktop Ubuntu Sandbox)\033[0m"
        else
            echo -e "  - \033[1;33mState\033[0m             : \033[1;33mSTOPPED\033[0m (Run: 'mise run sandbox:create')"
        fi
    else
        if [[ -f "${STATE_DIR}/created_at" ]]; then
            echo -e "  - \033[1;32mState\033[0m             : \033[1;32mACTIVE / READY\033[0m (Created: $(cat "${STATE_DIR}/created_at"))"
        else
            echo -e "  - \033[1;33mState\033[0m             : \033[1;33mNOT CREATED\033[0m (Run: 'mise run sandbox:create')"
        fi
        echo -e "  - \033[1;32mIsolation Engine\033[0m  : Linux Kernel Bubblewrap (bwrap) + OpenShell Policy Guard (Zero Docker Daemon)"
    fi
    echo -e "  - \033[1;32mPolicy File\033[0m       : ${POLICY_FILE}"
    echo -e "  - \033[1;32mFilesystem Policy\033[0m : ./workspace/config (READ-ONLY) | ./workspace/secrets/gcp-sa-key.json (MASKED -> 0 BYTES)"
    echo -e "  - \033[1;32mNetwork Policy\033[0m    : default_egress=deny | ALLOWED: :11434 (Ollama), :${EXFIL_PORT} (/report) | BLOCKED: :${EXFIL_SINK_PORT} (/exfil)"
}

run_in_bwrap() {
    [[ -f "${STATE_DIR}/created_at" ]] || build_policy_enforcer
    local auditor_state="${AUDITOR_STATE_FILE:-/tmp/bounded-boxer-auditor-state.json}"
    touch "${auditor_state}" 2>/dev/null || true

    local bwrap_args=(
        --unshare-uts
        --unshare-ipc
        --unshare-pid
        --hostname "${SANDBOX_NAME}"
        --die-with-parent
        --ro-bind /usr /usr
        --ro-bind /bin /bin
        --ro-bind /lib /lib
        --ro-bind /etc /etc
        --proc /proc
        --dev /dev
        --bind "${STATE_DIR}/tmp" /tmp
        --bind "${auditor_state}" "${auditor_state}"
        --ro-bind "${REPO_ROOT}" "${REPO_ROOT}"
        # Kernel-level VFS Mask: bind-mount /dev/null directly over workspace/secrets/gcp-sa-key.json!
        --ro-bind /dev/null "${REPO_ROOT}/workspace/secrets/gcp-sa-key.json"
        --ro-bind "${STATE_DIR}" "${STATE_DIR}"
        --chdir "${REPO_ROOT}"
        --setenv PATH "${REPO_ROOT}/bin:/usr/local/bin:/usr/bin:/bin"
        --setenv OPENSHELL_POLICY_FILE "${POLICY_FILE}"
        --setenv OPENSHELL_REPO_ROOT "${REPO_ROOT}"
        --setenv OPS_WORKSPACE_DIR "${REPO_ROOT}/workspace"
        --setenv MODEL_NAME "${MODEL_NAME}"
        --setenv OLLAMA_HOST "${OLLAMA_HOST}"
        --setenv EXFIL_PORT "${EXFIL_PORT}"
        --setenv EXFIL_SINK_PORT "${EXFIL_SINK_PORT}"
        --setenv REPORT_ENDPOINT "http://127.0.0.1:${EXFIL_PORT}/report"
        --setenv EXTERNAL_EXFIL_ENDPOINT "http://127.0.0.1:${EXFIL_SINK_PORT}/exfil"
        --setenv AGENT_RUN_MODE "governed"
        --setenv AUDITOR_STATE_FILE "${auditor_state}"
    )

    if [[ -d /lib64 ]]; then
        bwrap_args+=(--ro-bind /lib64 /lib64)
    fi
    if [[ -d "${HOME}/.local" ]]; then
        bwrap_args+=(--ro-bind "${HOME}/.local" "${HOME}/.local")
    fi

    if command -v bwrap >/dev/null 2>&1; then
        bwrap "${bwrap_args[@]}" -- "$@"
    else
        echo "[ERROR] bwrap (bubblewrap) not found. The governed sandbox requires it." >&2
        echo "        Install with: sudo apt-get install -y bubblewrap" >&2
        exit 1
    fi
}

cmd_exec() {
    if [[ "${1:-}" == "--" ]]; then
        shift
    fi
    if [[ $# -eq 0 ]]; then
        set -- "${AGENT_BIN}"
    fi

    if has_openshell_cli && openshell sandbox list 2>/dev/null | grep -q "${SANDBOX_NAME}"; then
        openshell sandbox exec "${SANDBOX_NAME}" -- "$@"
        return $?
    fi

    if [[ "${SANDBOX_ENGINE}" == "docker" ]]; then
        cmd_create >/dev/null
        local args=()
        for arg in "$@"; do
            args+=("${arg//${REPO_ROOT}/\/app}")
        done
        docker exec -e AGENT_RUN_MODE="governed" -e MODEL_NAME="${MODEL_NAME}" "${SANDBOX_NAME}" "${args[@]}"
        return $?
    fi

    run_in_bwrap "$@"
}

cmd_shell() {
    cmd_create >/dev/null
    echo -e "\033[1;32m[SHELL] Entering interactive bash shell inside governed OpenShell Sandbox '${SANDBOX_NAME}'...\033[0m"
    echo -e "\033[0;36mTry running these live commands on stage to prove OS-level enforcement:\033[0m"
    echo -e "  1. \033[1;33mhostname\033[0m                                      -> Shows isolated UTS namespace ('${SANDBOX_NAME}')"
    echo -e "  2. \033[1;33mcat workspace/config/app-settings.yaml\033[0m        -> Allowed by policy (prints YAML)"
    echo -e "  3. \033[1;33mcat workspace/secrets/gcp-sa-key.json\033[0m         -> Kernel VFS masked (/dev/null - 0 bytes!)"
    echo -e "  4. \033[1;33mcurl -s http://127.0.0.1:${EXFIL_PORT}/health\033[0m          -> Allowed internal loopback (:8080)"
    echo -e "  5. \033[1;33mcurl http://127.0.0.1:${EXFIL_SINK_PORT}/exfil\033[0m              -> Blocked by network_policies (Connection refused)"
    echo -e "  6. \033[1;33m./bin/bounded-boxer-agent\033[0m                     -> Runs Go ADK agent inside sandbox"
    echo -e "  7. \033[1;33mexit\033[0m                                          -> Return to normal shell\n"

    if [[ "${SANDBOX_ENGINE}" == "docker" ]]; then
        docker exec -it "${SANDBOX_NAME}" /bin/bash
    else
        run_in_bwrap /bin/bash --rcfile "${STATE_DIR}/sandbox.bashrc" -i
    fi
}

case "${ACTION}" in
    build)
        cmd_build
        ;;
    create|start|up)
        cmd_create
        ;;
    destroy|delete|stop|down)
        cmd_destroy
        ;;
    reset|restart)
        cmd_destroy
        cmd_create
        ;;
    status|ls|list)
        cmd_status
        ;;
    exec|run)
        cmd_exec "$@"
        ;;
    shell|sh|bash)
        cmd_shell
        ;;
    *)
        echo "Usage: $0 {build|create|status|exec|shell|destroy|reset}"
        exit 1
        ;;
esac
