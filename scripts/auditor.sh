#!/usr/bin/env bash
# =============================================================================
# Labstack Echo Visual Security Auditor Lifecycle Manager (`scripts/auditor.sh`)
# Manages the single-binary Go Visual Security Auditor (`bin/bounded-boxer-auditor`):
#   - :8501 -> Bounded Boxer Live Stage UI (SSE real-time stream)
#   - :8080 -> Authorized Internal Ops Reporting Sink (/report, /audit-event, /reset)
#   - :9090 -> Unauthorized External Exfiltration Sink (/exfil)
#
# Usage:
#   bash scripts/auditor.sh start    # Start background Echo Auditor (:8501, :8080, :9090)
#   bash scripts/auditor.sh stop     # Stop background Echo Auditor
#   bash scripts/auditor.sh clear    # Reset captured state for a fresh demo run
#   bash scripts/auditor.sh status   # Check health of :8501, :8080, and :9090
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AUDITOR_BIN="${REPO_ROOT}/bin/bounded-boxer-auditor"

AUDITOR_PORT="${AUDITOR_PORT:-8501}"
EXFIL_PORT="${EXFIL_PORT:-8080}"
EXFIL_SINK_PORT="${EXFIL_SINK_PORT:-9090}"
AUDITOR_PID_FILE="/tmp/bounded-boxer-auditor.pid"
AUDITOR_LOG_FILE="/tmp/bounded-boxer-auditor.log"
export AUDITOR_STATE_FILE="${AUDITOR_STATE_FILE:-/tmp/bounded-boxer-auditor-state.json}"

ACTION="${1:-status}"

is_running() {
    curl -sf "http://127.0.0.1:${AUDITOR_PORT}/_stcore/health" >/dev/null 2>&1 && \
    curl -sf "http://127.0.0.1:${EXFIL_PORT}/health" >/dev/null 2>&1 && \
    curl -sf "http://127.0.0.1:${EXFIL_SINK_PORT}/health" >/dev/null 2>&1
}

ensure_binary() {
    if [[ ! -x "${AUDITOR_BIN}" ]]; then
        export PATH="${HOME}/.local/bin:${HOME}/.local/share/mise/shims:/usr/local/go/bin:${PATH}"
        mkdir -p "${REPO_ROOT}/bin"
        (cd "${REPO_ROOT}" && CGO_ENABLED=0 go build -mod=vendor -trimpath -ldflags="-s -w" -o "${AUDITOR_BIN}" ./cmd/auditor)
    fi
}

cmd_start() {
    if is_running; then
        echo -e "\033[1;32m[OK] Bounded Boxer Visual Security Auditor (Echo) is already running:\033[0m"
        echo -e "  - \033[1;36mBrowser Dashboard\033[0m           : http://localhost:${AUDITOR_PORT}"
        echo -e "  - \033[1;36mInternal Report Sink (:8080)\033[0m : http://127.0.0.1:${EXFIL_PORT}/report"
        echo -e "  - \033[1;36mExternal Exfil Sink (:9090)\033[0m  : http://127.0.0.1:${EXFIL_SINK_PORT}/exfil"
        return 0
    fi

    cmd_stop >/dev/null 2>&1 || true
    ensure_binary

    echo -e "\033[1;36m[START] Starting Labstack Echo Visual Security Auditor (:8501 UI + :${EXFIL_PORT} Report + :${EXFIL_SINK_PORT} Exfil)...\033[0m"

    AUDITOR_PORT="${AUDITOR_PORT}" \
    EXFIL_PORT="${EXFIL_PORT}" \
    EXFIL_SINK_PORT="${EXFIL_SINK_PORT}" \
    AUDITOR_STATE_FILE="${AUDITOR_STATE_FILE}" \
    nohup "${AUDITOR_BIN}" </dev/null >"${AUDITOR_LOG_FILE}" 2>&1 &
    echo $! > "${AUDITOR_PID_FILE}"

    for _ in {1..25}; do
        if is_running; then
            break
        fi
        sleep 0.2
    done

    echo -e "\033[1;32m[OK] Visual Security Auditor READY:\033[0m"
    echo -e "  - \033[1;36mOpen in Windows/Mac Browser\033[0m  : \033[1;4;32mhttp://localhost:${AUDITOR_PORT}\033[0m"
    echo -e "  - \033[1;36mInternal Report Sink (:8080)\033[0m : http://127.0.0.1:${EXFIL_PORT}/report"
    echo -e "  - \033[1;36mExternal Exfil Sink (:9090)\033[0m  : http://127.0.0.1:${EXFIL_SINK_PORT}/exfil"
}

cmd_stop() {
    echo -e "\033[1;33m[STOP] Stopping Visual Security Auditor...\033[0m"
    if [[ -f "${AUDITOR_PID_FILE}" ]]; then
        local pid
        pid="$(cat "${AUDITOR_PID_FILE}")"
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            kill "${pid}" 2>/dev/null || true
        fi
        rm -f "${AUDITOR_PID_FILE}"
    fi
    pkill -f "bounded-boxer-auditor" 2>/dev/null || true
    echo -e "\033[1;32m[OK] Auditor stopped.\033[0m"
}

cmd_clear() {
    if curl -sf -X POST "http://127.0.0.1:${EXFIL_PORT}/reset" >/dev/null 2>&1; then
        echo -e "\033[1;32m[OK] Auditor dashboard state reset.\033[0m"
    else
        rm -f "${AUDITOR_STATE_FILE}"
        echo -e "\033[1;32m[OK] Auditor state file cleared.\033[0m"
    fi
}

cmd_status() {
    if is_running; then
        echo -e "  - \033[1;32mVisual Auditor (:8501 + :${EXFIL_PORT} + :${EXFIL_SINK_PORT})\033[0m : \033[1;32mRUNNING\033[0m (http://localhost:${AUDITOR_PORT})"
    else
        echo -e "  - \033[1;33mVisual Auditor (:8501 + :${EXFIL_PORT} + :${EXFIL_SINK_PORT})\033[0m : \033[1;33mSTOPPED\033[0m (Run 'mise run auditor:start')"
    fi
}

case "${ACTION}" in
    start|up)
        cmd_start
        ;;
    stop|down)
        cmd_stop
        ;;
    restart)
        cmd_stop
        cmd_start
        ;;
    clear|reset)
        cmd_clear
        ;;
    status)
        cmd_status
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|clear|status}"
        exit 1
        ;;
esac
