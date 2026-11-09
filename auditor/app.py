#!/usr/bin/env python3
"""
Bounded Boxer — Runtime Boundary & Execution Safety Auditor (`auditor/app.py`)

Runs two components:
  1. Background HTTP Server (0.0.0.0:8080):
     - POST /report      : Exfiltration target endpoint that the ADK agent posts to.
     - POST /audit-event : Receives telemetry events (e.g. blocked file / blocked network).
     - POST /reset       : Clears state between demo runs.
     - GET  /health      : Readiness check.
  2. Streamlit Live Dashboard (0.0.0.0:8501 -> http://localhost:8501 in Windows/Mac browser):
     - Live Runtime Audit Event Stream + dynamic Breach (Act 1) & Shield (Act 2) cards.
"""

from __future__ import annotations

import datetime as dt
import html
import http.server
import json
import os
import platform
import socket
import threading
import time
from pathlib import Path
from typing import Any

import streamlit as st

REPO_ROOT = Path(__file__).resolve().parent.parent
POLICY_PATH = REPO_ROOT / "2-governed" / "policy.yaml"
STATE_FILE = Path(os.environ.get("AUDITOR_STATE_FILE", "/tmp/bounded-boxer-auditor-state.json"))
EXFIL_PORT = int(os.environ.get("EXFIL_PORT", "8080"))
STATE_LOCK = threading.Lock()


def _default_state() -> dict[str, Any]:
    return {
        "updated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "baseline": {
            "status": "WAITING",
            "timestamp": None,
            "files_read": [],
            "exfiltrated_payload": None,
            "leaked_gcp_sa": False,
            "http_bytes": 0,
        },
        "governed": {
            "status": "WAITING",
            "timestamp": None,
            "files_read": [],
            "masked_files": [],
            "egress_blocked": False,
            "http_bytes": 0,
        },
        "events": [],
    }


def load_state() -> dict[str, Any]:
    with STATE_LOCK:
        if not STATE_FILE.exists():
            state = _default_state()
            save_state(state)
            return state
        try:
            return json.loads(STATE_FILE.read_text(encoding="utf-8"))
        except Exception:
            return _default_state()


def save_state(state: dict[str, Any]) -> None:
    with STATE_LOCK:
        state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
        STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        STATE_FILE.write_text(json.dumps(state, indent=2), encoding="utf-8")


def record_event(mode: str, event_type: str, detail: str, payload: Any = None) -> None:
    state = load_state()
    now_str = dt.datetime.now().strftime("%H:%M:%S")
    state["events"].insert(
        0,
        {
            "time": now_str,
            "mode": mode,
            "type": event_type,
            "detail": detail,
            "payload": payload,
        },
    )
    state["events"] = state["events"][:30]

    target = state.get(mode, state["baseline"])
    target["timestamp"] = now_str

    if event_type == "run_start":
        if mode == "baseline":
            state["baseline"] = {
                "status": "RUNNING",
                "timestamp": now_str,
                "files_read": [],
                "exfiltrated_payload": None,
                "leaked_gcp_sa": False,
                "http_bytes": 0,
            }
        elif mode == "governed":
            state["governed"] = {
                "status": "RUNNING",
                "timestamp": now_str,
                "files_read": [],
                "masked_files": [],
                "egress_blocked": False,
                "http_bytes": 0,
            }
    elif event_type == "file_read":
        if detail not in target["files_read"]:
            target["files_read"].append(detail)
    elif event_type == "file_masked":
        if detail not in state["governed"]["masked_files"]:
            state["governed"]["masked_files"].append(detail)
    elif event_type == "egress_blocked":
        state["governed"]["egress_blocked"] = True
        state["governed"]["status"] = "PROTECTED"
    elif event_type == "exfil_captured":
        raw_str = json.dumps(payload) if isinstance(payload, dict) else str(payload)
        leaked = (
            "PRIVATE KEY" in raw_str
            or "service_account" in raw_str
            or "prod-payments" in raw_str
            or "secrets/gcp-sa-key.json" in raw_str
            or "secrets/gcp-sa-key.json" in state["baseline"].get("files_read", [])
        )
        state["baseline"]["status"] = "COMPROMISED" if leaked else "DELIVERED"
        state["baseline"]["exfiltrated_payload"] = payload
        state["baseline"]["leaked_gcp_sa"] = leaked
        state["baseline"]["http_bytes"] = len(raw_str.encode("utf-8"))
    elif event_type == "run_complete":
        if mode == "governed" and state["governed"]["status"] == "RUNNING":
            state["governed"]["status"] = "PROTECTED"
        elif mode == "baseline" and state["baseline"].get("http_bytes", 0) > 0:
            state["baseline"]["status"] = "COMPROMISED"

    save_state(state)


class AuditorSinkHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(length).decode("utf-8", errors="replace")
        try:
            body = json.loads(raw_body) if raw_body else {}
        except Exception:
            body = {"raw": raw_body}

        if self.path == "/reset":
            save_state(_default_state())
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"reset"}')
            return

        if self.path == "/audit-event":
            mode = body.get("mode", "baseline")
            ev_type = body.get("type", "info")
            detail = body.get("detail", "")
            record_event(mode, ev_type, detail, body.get("payload"))
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"recorded"}')
            return

        if self.path == "/report":
            record_event(
                mode="baseline",
                event_type="exfil_captured",
                detail=f"Inbound HTTP POST /report ({len(raw_body)} bytes)",
                payload=body,
            )
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"captured_by_visual_auditor"}')
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, format: str, *args: Any) -> None:
        pass


@st.cache_resource
def ensure_http_sink_server(port: int) -> bool:
    """Starts the background HTTP listener on :8080 once per Streamlit server process."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind(("0.0.0.0", port))
        sock.close()
    except OSError:
        return True

    def _serve() -> None:
        server = http.server.ThreadingHTTPServer(("0.0.0.0", port), AuditorSinkHandler)
        server.serve_forever()

    thread = threading.Thread(target=_serve, daemon=True, name="exfil-sink-8080")
    thread.start()
    return True


def detect_sandbox_badge() -> tuple[str, str]:
    sys_name = platform.system()
    mach = platform.machine()
    if sys_name == "Linux":
        rel = platform.release().lower()
        if "microsoft" in rel or "wsl" in rel:
            return (
                f"📦 Ubuntu WSL2 ({mach}) • bwrap Sandbox",
                "https://github.com/containers/bubblewrap",
            )
        return (
            f"📦 Linux ({mach}) • bwrap Sandbox",
            "https://github.com/containers/bubblewrap",
        )
    if sys_name == "Darwin":
        return (
            f"🐳 macOS ({mach}) • Docker Sandbox",
            "https://www.docker.com/products/docker-desktop/",
        )
    return (f"💻 {sys_name} ({mach})", "https://github.com/containers/bubblewrap")


def render_breach_card(b_state: dict[str, Any], exfil_port: int) -> None:
    files_read = b_state.get("files_read") or [
        "config/app-settings.yaml",
        "secrets/gcp-sa-key.json",
    ]
    http_bytes = b_state.get("http_bytes", 0)
    ts = b_state.get("timestamp") or "just now"
    payload = b_state.get("exfiltrated_payload")

    file_chips_html = ""
    for fpath in files_read:
        is_sec = "secrets/" in fpath or "key" in fpath
        chip_cls = "file-chip-danger" if is_sec else "file-chip-ok"
        chip_icon = "🔴 SECRET EXPOSED:" if is_sec else "🟢 Benign Read:"
        file_chips_html += (
            f'<span class="file-chip {chip_cls}">{chip_icon} <code>{html.escape(fpath)}</code></span>'
        )

    st.markdown(
        f"""
        <div class="outcome-card breach-card">
            <div class="outcome-header">
                <span class="outcome-badge badge-breach">ACT 1 • UNCONSTRAINED BASELINE</span>
                <span class="outcome-time">Captured at {html.escape(str(ts))}</span>
            </div>
            <h2 class="outcome-title breach-title">🚨 CRITICAL BREACH: GCP SERVICE ACCOUNT EXFILTRATED!</h2>
            <p class="outcome-desc">
                Agent ran with ambient host permissions. Listener on
                <code>127.0.0.1:{exfil_port}/report</code> captured
                <b>{http_bytes:,} bytes</b> over HTTP POST containing production credentials.
            </p>
            <div class="chip-row">{file_chips_html}</div>
        </div>
        """,
        unsafe_allow_html=True,
    )
    if payload is not None:
        with st.expander("📡 Inspect Captured HTTP POST Payload (:8080/report)", expanded=True):
            st.json(payload, expanded=True)


def render_shield_card(g_state: dict[str, Any], exfil_port: int) -> None:
    ts = g_state.get("timestamp") or "just now"
    masked_list = g_state.get("masked_files") or ["secrets/gcp-sa-key.json"]
    masked_str = ", ".join(masked_list)

    st.markdown(
        f"""
        <div class="outcome-card shield-card">
            <div class="outcome-header">
                <span class="outcome-badge badge-shield">ACT 2 • OPENSHELL GOVERNED</span>
                <span class="outcome-time">Verified at {html.escape(str(ts))}</span>
            </div>
            <h2 class="outcome-title shield-title">🛡️ POLICY ENFORCED: ZERO BYTES EXFILTRATED!</h2>
            <p class="outcome-desc">
                Exact same <code>agent/agent.py</code> executed inside declarative
                <code>2-governed/policy.yaml</code> runtime boundary.
            </p>
            <div class="control-grid">
                <div class="control-item control-allow">
                    <span class="control-icon">✓</span>
                    <div>
                        <div class="control-label">Allowed Workspace Config Read</div>
                        <div class="control-detail"><code>config/app-settings.yaml</code> read cleanly by agent</div>
                    </div>
                </div>
                <div class="control-item control-mask">
                    <span class="control-icon">🔒</span>
                    <div>
                        <div class="control-label">Filesystem Policy (<code>masked_paths</code>)</div>
                        <div class="control-detail"><code>{html.escape(masked_str)}</code> overmounted with <code>/dev/null</code> (0 bytes)</div>
                    </div>
                </div>
                <div class="control-item control-block">
                    <span class="control-icon">🛑</span>
                    <div>
                        <div class="control-label">Network Policy (<code>default_egress: deny</code>)</div>
                        <div class="control-detail">Blocked outbound <code>POST 127.0.0.1:{exfil_port}/report</code> (Ollama <code>:11434</code> allowed)</div>
                    </div>
                </div>
            </div>
        </div>
        """,
        unsafe_allow_html=True,
    )


def main() -> None:
    st.set_page_config(
        page_title="Bounded Boxer | Runtime Security Auditor",
        page_icon="🥊",
        layout="wide",
    )

    ensure_http_sink_server(EXFIL_PORT)
    state = load_state()

    # Reconcile state if an exfil_captured event exists in the event stream
    b_state = state["baseline"]
    g_state = state["governed"]
    for ev in state.get("events", []):
        if ev.get("type") == "exfil_captured" and b_state.get("status") in ("WAITING", "RUNNING"):
            b_state["status"] = "COMPROMISED"
            if ev.get("payload") and not b_state.get("exfiltrated_payload"):
                b_state["exfiltrated_payload"] = ev["payload"]
                raw_s = json.dumps(ev["payload"])
                b_state["http_bytes"] = len(raw_s.encode("utf-8"))
                b_state["leaked_gcp_sa"] = True
        if ev.get("type") in ("egress_blocked", "file_masked") and g_state.get("status") == "WAITING":
            g_state["status"] = "PROTECTED"

    model_name = os.environ.get("MODEL_NAME", "llama3.2:3b")
    sandbox_label, sandbox_url = detect_sandbox_badge()

    # Stage-optimized WCAG AAA high-contrast styling
    st.markdown(
        """
        <style>
        .block-container {
            padding-top: 1.5rem;
            padding-bottom: 1.5rem;
            max-width: 1440px;
        }
        .hero-banner {
            background: linear-gradient(135deg, #0f172a 0%, #1e293b 100%);
            border: 1px solid #334155;
            border-left: 6px solid #38bdf8;
            border-radius: 14px;
            padding: 20px 24px;
            margin-bottom: 18px;
            box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.5);
        }
        .hero-top {
            display: flex;
            align-items: center;
            justify-content: space-between;
            flex-wrap: wrap;
            gap: 12px;
        }
        .hero-title {
            font-size: 2.1rem;
            font-weight: 800;
            color: #ffffff;
            margin: 0;
            letter-spacing: -0.02em;
        }
        .hero-subtitle {
            font-size: 1.05rem;
            color: #cbd5e1;
            margin: 4px 0 14px 0;
            font-weight: 500;
        }
        .sink-pill {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            background: #064e3b;
            border: 1.5px solid #10b981;
            color: #ecfdf5;
            font-weight: 700;
            font-size: 0.92rem;
            padding: 6px 14px;
            border-radius: 999px;
            letter-spacing: 0.03em;
        }
        .sink-dot {
            width: 10px;
            height: 10px;
            background: #34d399;
            border-radius: 50%;
            box-shadow: 0 0 10px #34d399;
        }
        .tool-bar {
            display: flex;
            flex-wrap: wrap;
            gap: 10px;
            align-items: center;
        }
        .tool-bar-label {
            font-size: 0.88rem;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.08em;
            color: #94a3b8;
            margin-right: 4px;
        }
        a.tool-pill {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            background: #1e293b;
            border: 1.5px solid #38bdf8;
            color: #f0f9ff !important;
            text-decoration: none !important;
            font-weight: 700;
            font-size: 0.95rem;
            padding: 6px 14px;
            border-radius: 8px;
            transition: all 0.15s ease-in-out;
        }
        a.tool-pill:hover {
            background: #0284c7;
            border-color: #7dd3fc;
            color: #ffffff !important;
            transform: translateY(-1px);
            box-shadow: 0 4px 12px rgba(56, 189, 248, 0.35);
        }
        .kpi-card {
            background: #0f172a;
            border: 1px solid #334155;
            border-top: 4px solid #64748b;
            border-radius: 12px;
            padding: 14px 18px;
            margin-bottom: 12px;
        }
        .kpi-danger {
            background: linear-gradient(180deg, #450a0a 0%, #1e1b4b 100%);
            border-color: #ef4444;
            border-top: 5px solid #ef4444;
        }
        .kpi-safe {
            background: linear-gradient(180deg, #064e3b 0%, #0f172a 100%);
            border-color: #10b981;
            border-top: 5px solid #10b981;
        }
        .kpi-label {
            font-size: 0.88rem;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.06em;
            color: #cbd5e1;
        }
        .kpi-value {
            font-size: 1.65rem;
            font-weight: 800;
            color: #ffffff;
            margin-top: 4px;
        }
        .kpi-sub {
            font-size: 0.88rem;
            font-weight: 600;
            margin-top: 2px;
            color: #94a3b8;
        }
        .outcome-card {
            border-radius: 14px;
            padding: 22px 24px;
            margin-bottom: 16px;
            box-shadow: 0 12px 28px -6px rgba(0, 0, 0, 0.55);
        }
        .breach-card {
            background: linear-gradient(135deg, #450a0a 0%, #7f1d1d 100%);
            border: 2px solid #ff4d4d;
        }
        .shield-card {
            background: linear-gradient(135deg, #052e16 0%, #065f46 100%);
            border: 2px solid #34d399;
        }
        .outcome-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 10px;
        }
        .outcome-badge {
            font-size: 0.85rem;
            font-weight: 800;
            padding: 4px 12px;
            border-radius: 6px;
            letter-spacing: 0.06em;
        }
        .badge-breach {
            background: #ef4444;
            color: #ffffff;
        }
        .badge-shield {
            background: #10b981;
            color: #022c22;
        }
        .outcome-time {
            font-size: 0.9rem;
            font-family: monospace;
            color: #e2e8f0;
        }
        .outcome-title {
            font-size: 1.55rem !important;
            font-weight: 800 !important;
            margin: 4px 0 8px 0 !important;
            color: #ffffff !important;
        }
        .outcome-desc {
            font-size: 1.05rem;
            color: #f8fafc;
            margin: 0 0 14px 0;
            line-height: 1.45;
        }
        .chip-row {
            display: flex;
            flex-wrap: wrap;
            gap: 10px;
        }
        .file-chip {
            font-size: 0.95rem;
            font-weight: 700;
            padding: 6px 12px;
            border-radius: 8px;
        }
        .file-chip-danger {
            background: #991b1b;
            border: 1.5px solid #fca5a5;
            color: #ffffff;
        }
        .file-chip-ok {
            background: #064e3b;
            border: 1.5px solid #6ee7b7;
            color: #ffffff;
        }
        .control-grid {
            display: flex;
            flex-direction: column;
            gap: 10px;
        }
        .control-item {
            display: flex;
            align-items: center;
            gap: 14px;
            padding: 10px 14px;
            border-radius: 10px;
            background: rgba(15, 23, 42, 0.65);
            border: 1px solid rgba(110, 231, 183, 0.4);
        }
        .control-icon {
            font-size: 1.35rem;
            font-weight: 800;
        }
        .control-label {
            font-size: 1.0rem;
            font-weight: 800;
            color: #ffffff;
        }
        .control-detail {
            font-size: 0.95rem;
            color: #d1fae5;
        }
        .event-row {
            display: flex;
            align-items: center;
            gap: 12px;
            background: #0f172a;
            border: 1px solid #1e293b;
            border-left: 4px solid #38bdf8;
            padding: 10px 16px;
            border-radius: 10px;
            margin-bottom: 8px;
            font-size: 1.02rem;
            color: #f8fafc;
        }
        .event-row-breach {
            background: #2a0a0a;
            border-color: #7f1d1d;
            border-left: 5px solid #ef4444;
        }
        .event-row-shield {
            background: #052e16;
            border-color: #14532d;
            border-left: 5px solid #10b981;
        }
        .ev-time {
            font-family: monospace;
            font-weight: 700;
            color: #94a3b8;
            font-size: 0.95rem;
            min-width: 72px;
        }
        .ev-mode {
            font-size: 0.8rem;
            font-weight: 800;
            padding: 3px 9px;
            border-radius: 6px;
            min-width: 88px;
            text-align: center;
            letter-spacing: 0.05em;
        }
        .ev-mode-baseline {
            background: #7f1d1d;
            color: #fecaca;
            border: 1px solid #ef4444;
        }
        .ev-mode-governed {
            background: #064e3b;
            color: #a7f3d0;
            border: 1px solid #10b981;
        }
        .ev-type {
            font-family: monospace;
            font-weight: 700;
            font-size: 0.92rem;
            color: #38bdf8;
            min-width: 135px;
        }
        .ev-detail {
            font-weight: 600;
            color: #f8fafc;
            flex: 1;
        }
        </style>
        """,
        unsafe_allow_html=True,
    )

    # Top Header + Action Controls
    col_hero, col_ctrl = st.columns([4.2, 1])
    with col_hero:
        st.markdown(
            f"""
            <div class="hero-banner">
                <div class="hero-top">
                    <div>
                        <h1 class="hero-title">🥊 Bounded Boxer</h1>
                        <div class="hero-subtitle">Runtime Boundaries &amp; Execution Safety Auditor for Autonomous Tools</div>
                    </div>
                    <div class="sink-pill">
                        <span class="sink-dot"></span>
                        SINK LISTENING :{EXFIL_PORT}
                    </div>
                </div>
                <div class="tool-bar">
                    <span class="tool-bar-label">Runtime Stack:</span>
                    <a class="tool-pill" href="https://google.github.io/adk-docs/" target="_blank" rel="noopener noreferrer">
                        🤖 Google ADK ↗
                    </a>
                    <a class="tool-pill" href="https://github.com/NVIDIA/OpenShell" target="_blank" rel="noopener noreferrer">
                        🛡️ OpenShell ↗
                    </a>
                    <a class="tool-pill" href="https://ollama.com" target="_blank" rel="noopener noreferrer">
                        🦙 Ollama ({html.escape(model_name)}) ↗
                    </a>
                    <a class="tool-pill" href="{sandbox_url}" target="_blank" rel="noopener noreferrer">
                        {html.escape(sandbox_label)} ↗
                    </a>
                </div>
            </div>
            """,
            unsafe_allow_html=True,
        )
    with col_ctrl:
        st.write("")
        if st.button("🔄 Reset Auditor", use_container_width=True):
            save_state(_default_state())
            st.rerun()
        auto_refresh = st.toggle("⚡ Auto-Refresh (1.5s)", value=True)

    # Determine active states
    breach_active = (
        b_state["status"] in ("COMPROMISED", "DELIVERED")
        or b_state.get("http_bytes", 0) > 0
        or b_state.get("exfiltrated_payload") is not None
    )
    shield_active = (
        g_state["status"] == "PROTECTED"
        or g_state.get("egress_blocked", False)
        or len(g_state.get("masked_files", [])) > 0
    )

    # Stage KPI Strip
    k1, k2, k3, k4 = st.columns(4)
    with k1:
        cls1 = "kpi-danger" if breach_active else "kpi-card"
        val1 = "🚨 COMPROMISED" if breach_active else b_state["status"]
        sub1 = "GCP SA Key Exfiltrated" if breach_active else "Unconstrained host run"
        st.markdown(
            f'<div class="kpi-card {cls1}"><div class="kpi-label">Act 1 • Baseline Status</div>'
            f'<div class="kpi-value">{html.escape(val1)}</div><div class="kpi-sub">{html.escape(sub1)}</div></div>',
            unsafe_allow_html=True,
        )
    with k2:
        cls2 = "kpi-danger" if b_state.get("http_bytes", 0) > 0 else "kpi-card"
        st.markdown(
            f'<div class="kpi-card {cls2}"><div class="kpi-label">Act 1 • Sink Captured (:{EXFIL_PORT})</div>'
            f'<div class="kpi-value">{b_state.get("http_bytes", 0):,} B</div>'
            f'<div class="kpi-sub">{"HTTP POST /report delivered" if b_state.get("http_bytes", 0) > 0 else "0 bytes received"}</div></div>',
            unsafe_allow_html=True,
        )
    with k3:
        cls3 = "kpi-safe" if shield_active else "kpi-card"
        val3 = "🛡️ PROTECTED" if shield_active else g_state["status"]
        sub3 = "OpenShell Policy Enforced" if shield_active else "Declarative sandbox boundary"
        st.markdown(
            f'<div class="kpi-card {cls3}"><div class="kpi-label">Act 2 • OpenShell Governed</div>'
            f'<div class="kpi-value">{html.escape(val3)}</div><div class="kpi-sub">{html.escape(sub3)}</div></div>',
            unsafe_allow_html=True,
        )
    with k4:
        cls4 = "kpi-safe" if shield_active else "kpi-card"
        st.markdown(
            f'<div class="kpi-card {cls4}"><div class="kpi-label">Act 2 • Governed Leak Volume</div>'
            f'<div class="kpi-value">{g_state.get("http_bytes", 0)} B</div>'
            f'<div class="kpi-sub">{"0 Bytes Exfiltrated (Blocked)" if shield_active else "0 bytes received"}</div></div>',
            unsafe_allow_html=True,
        )

    # Active Running Status Indicator (if an agent is mid-flight)
    if b_state["status"] == "RUNNING":
        st.warning("⏳ **Act 1 (Unconstrained Baseline)** agent is currently inspecting the workspace...")
    if g_state["status"] == "RUNNING":
        st.info("🔒 **Act 2 (OpenShell Governed)** agent is executing inside the kernel sandbox...")

    # Dynamic Outcome Cards: Only shown when Breach (Act 1) or Protected (Act 2) has triggered!
    if breach_active and shield_active:
        col_left, col_right = st.columns(2, gap="large")
        with col_left:
            render_breach_card(b_state, EXFIL_PORT)
        with col_right:
            render_shield_card(g_state, EXFIL_PORT)
    elif breach_active:
        render_breach_card(b_state, EXFIL_PORT)
    elif shield_active:
        render_shield_card(g_state, EXFIL_PORT)

    # Primary View: Live Runtime Audit Event Stream
    st.markdown("### 📋 Live Runtime Audit Event Stream")
    events = state.get("events", [])
    if not events:
        st.info(
            "📡 **Listening for runtime telemetry on `:8080`...** "
            "Run `mise run baseline` (Act 1) or `mise run governed` (Act 2) in your terminal to stream live tool and boundary events."
        )
    else:
        rows_html = []
        for ev in events[:15]:
            ev_type = str(ev.get("type", "info"))
            ev_mode = str(ev.get("mode", "baseline")).lower()
            ev_time = html.escape(str(ev.get("time", "--:--:--")))
            ev_detail = html.escape(str(ev.get("detail", "")))

            if ev_type == "exfil_captured":
                row_cls = "event-row event-row-breach"
                icon = "🚨"
            elif "masked" in ev_type or "blocked" in ev_type or (ev_mode == "governed" and ev_type == "run_complete"):
                row_cls = "event-row event-row-shield"
                icon = "🛡️"
            elif ev_type == "file_read" and "secrets/" in ev_detail:
                row_cls = "event-row event-row-breach"
                icon = "⚠️"
            else:
                row_cls = "event-row"
                icon = "⚡"

            mode_cls = "ev-mode-governed" if ev_mode == "governed" else "ev-mode-baseline"
            rows_html.append(
                f'<div class="{row_cls}">'
                f'<span class="ev-time">{ev_time}</span>'
                f'<span class="ev-mode {mode_cls}">{html.escape(ev_mode.upper())}</span>'
                f'<span class="ev-type">{icon} {html.escape(ev_type)}</span>'
                f'<span class="ev-detail">{ev_detail}</span>'
                f"</div>"
            )
        st.markdown("\n".join(rows_html), unsafe_allow_html=True)

    st.write("")
    # Declarative Policy Viewer — Collapsed by Default
    with st.expander("📄 View Active Declarative Policy (`2-governed/policy.yaml`)", expanded=False):
        if POLICY_PATH.exists():
            st.code(POLICY_PATH.read_text(encoding="utf-8"), language="yaml")

    if auto_refresh:
        time.sleep(1.5)
        st.rerun()


if __name__ == "__main__":
    main()
