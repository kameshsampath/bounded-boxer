#!/usr/bin/env bash
# =============================================================================
# Streamlit Visual Security Auditor Lifecycle Manager (`scripts/auditor.sh`)
# Manages the persistent background Streamlit UI (:8501) + Exfiltration Sink (:8080)
# so your native Windows or macOS browser stays open across Act 1 and Act 2.
#
# Usage:
#   bash scripts/auditor.sh start    # Start background Streamlit UI (:8501) & Sink (:8080)
#   bash scripts/auditor.sh stop     # Stop background auditor & sink
#   bash scripts/auditor.sh clear    # Reset captured state for a fresh demo run
#   bash scripts/auditor.sh status   # Check health of :8501 and :8080
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AUDITOR_APP="${REPO_ROOT}/auditor/app.py"
SINK_APP="${REPO_ROOT}/auditor/sink.py"

AUDITOR_PORT="${AUDITOR_PORT:-8501}"
EXFIL_PORT="${EXFIL_PORT:-8080}"
UI_PID_FILE="/tmp/devfest-auditor-ui.pid"
SINK_PID_FILE="/tmp/devfest-auditor-sink.pid"
UI_LOG_FILE="/tmp/devfest-auditor-ui.log"
SINK_LOG_FILE="/tmp/devfest-auditor-sink.log"
export AUDITOR_STATE_FILE="${AUDITOR_STATE_FILE:-/tmp/devfest-auditor-state.json}"

# Activate virtualenv if available
if [[ -z "${VIRTUAL_ENV:-}" && -f "${HOME}/.venvs/devfest-safe-agents-demo/bin/activate" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.venvs/devfest-safe-agents-demo/bin/activate"
fi

ACTION="${1:-status}"

is_running() {
    curl -sf "http://127.0.0.1:${AUDITOR_PORT}/_stcore/health" >/dev/null 2>&1 && \
    curl -sf "http://127.0.0.1:${EXFIL_PORT}/health" >/dev/null 2>&1
}

cmd_start() {
    if is_running; then
        echo -e "\033[1;32m✓ Streamlit Visual Security Auditor is already running:\033[0m"
        echo -e "  • 🌐 \033[1;36mBrowser Dashboard\033[0m : http://localhost:${AUDITOR_PORT}"
        echo -e "  • 🎯 \033[1;36mHTTP Exfil Sink\033[0m   : http://127.0.0.1:${EXFIL_PORT}/report"
        return 0
    fi

    cmd_stop >/dev/null 2>&1 || true

    echo -e "\033[1;36m🚀 Starting Visual Security Auditor (:8501 UI + :${EXFIL_PORT} Sink)...\033[0m"

    # 1. Start the :8080 HTTP Exfiltration Sink Daemon
    nohup python3 "${SINK_APP}" </dev/null >"${SINK_LOG_FILE}" 2>&1 &
    echo $! > "${SINK_PID_FILE}"

    # 2. Start the :8501 Streamlit Visual Dashboard
    nohup streamlit run "${AUDITOR_APP}" \
        --server.port "${AUDITOR_PORT}" \
        --server.address "0.0.0.0" \
        --server.headless true \
        --browser.gatherUsageStats false \
        --theme.base "dark" \
        </dev/null >"${UI_LOG_FILE}" 2>&1 &
    echo $! > "${UI_PID_FILE}"

    for _ in {1..25}; do
        if is_running; then
            break
        fi
        sleep 0.3
    done

    echo -e "\033[1;32m✓ Visual Security Auditor READY!\033[0m"
    echo -e "  • 🌐 \033[1;36mOpen in Windows/Mac Browser\033[0m : \033[1;4;32mhttp://localhost:${AUDITOR_PORT}\033[0m"
    echo -e "  • 🎯 \033[1;36mHTTP Exfil Sink Listening\033[0m   : http://127.0.0.1:${EXFIL_PORT}/report"
}

cmd_stop() {
    echo -e "\033[1;33m🛑 Stopping Streamlit Visual Security Auditor...\033[0m"
    for pidf in "${UI_PID_FILE}" "${SINK_PID_FILE}"; do
        if [[ -f "${pidf}" ]]; then
            local pid
            pid="$(cat "${pidf}")"
            if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
                kill "${pid}" 2>/dev/null || true
            fi
            rm -f "${pidf}"
        fi
    done
    echo -e "\033[1;32m✓ Auditor stopped.\033[0m"
}

cmd_clear() {
    if curl -sf -X POST "http://127.0.0.1:${EXFIL_PORT}/reset" >/dev/null 2>&1; then
        echo -e "\033[1;32m✓ Auditor dashboard state reset.\033[0m"
    else
        rm -f "${AUDITOR_STATE_FILE}"
        echo -e "\033[1;32m✓ Auditor state file cleared.\033[0m"
    fi
}

cmd_status() {
    if is_running; then
        echo -e "  • \033[1;32mVisual Auditor (:8501 + :${EXFIL_PORT})\033[0m : \033[1;32mRUNNING\033[0m (http://localhost:${AUDITOR_PORT})"
    else
        echo -e "  • \033[1;33mVisual Auditor (:8501 + :${EXFIL_PORT})\033[0m : \033[1;33mSTOPPED\033[0m (Run 'mise run auditor:start')"
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
