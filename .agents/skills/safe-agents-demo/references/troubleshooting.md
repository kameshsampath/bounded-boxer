# Troubleshooting & Remediation Reference (`safe-agents-demo`)

Use this reference when `scripts/doctor.sh` or `scripts/test-offline.sh` reports warnings or failures.

---

## 1. Windows 11 + Ubuntu WSL2 Issues

### A. WSL2 RAM Exceeds 8GB or `.wslconfig` Not Applied
- **Symptom**: `test-offline.sh` warns that WSL2 RAM is `> 8600 MB`.
- **Fix**:
  1. From Windows PowerShell, run `.\scripts\provision.ps1` (which writes `%USERPROFILE%\.wslconfig` with `memory=8GB`).
  2. Run `wsl.exe --shutdown` in PowerShell and reopen Ubuntu WSL2.

### B. `bwrap: command not found` inside WSL2
- **Fix**:
  ```bash
  sudo apt-get update -qq && sudo apt-get install -y -qq bubblewrap netcat-openbsd jq curl
  ```

### C. CRLF (`\r\n`) Line Ending Errors on `.sh` Scripts in `/mnt/d/`
- **Symptom**: `/usr/bin/env: 'bash\r': No such file or directory`
- **Fix**:
  ```bash
  find . -maxdepth 4 \( -name "*.sh" -o -name "*.py" -o -name "*.yaml" -o -name "*.toml" \) -exec sed -i 's/\r$//' {} +
  ```

---

## 2. macOS (Apple Silicon) + Docker Desktop Issues

### A. `Cannot connect to the Docker daemon` on macOS
- **Symptom**: `doctor.sh` reports Docker Desktop is not running.
- **Fix**:
  ```bash
  open -a Docker
  # Wait ~10 seconds for Docker Desktop engine to initialize, then verify:
  docker info
  ```

### B. Sandbox Container Cannot Reach Ollama on macOS
- **Symptom**: Inside the Docker container on macOS, `127.0.0.1:11434` refers to the container loopback rather than the macOS host.
- **How `scripts/sandbox.sh` handles this automatically**:
  - When `uname -s` is `Darwin`, `scripts/sandbox.sh` automatically sets `OLLAMA_HOST=http://host.docker.internal:11434` inside the container and adds `host.docker.internal:11434` to the allowed endpoints in the OpenShell policy hook.

---

## 3. Ollama & Local Model Issues

### A. Ollama Not Installed or Daemon Not Listening on `:11434`
- **On Ubuntu WSL2**:
  ```bash
  curl -fsSL https://ollama.com/install.sh | sh
  nohup ollama serve </dev/null >/tmp/ollama.log 2>&1 &
  sleep 2
  ollama pull llama3.2:3b
  ```
- **On macOS**:
  ```bash
  brew install ollama
  nohup ollama serve </dev/null >/tmp/ollama-mac.log 2>&1 &
  sleep 2
  ollama pull llama3.2:3b
  ```

### B. Pinning the Model in RAM for Zero Cold-Start Latency on Stage
- Run:
  ```bash
  curl -sf http://127.0.0.1:11434/api/generate \
    -d '{"model": "llama3.2:3b", "prompt": "ping", "stream": false, "keep_alive": -1}'
  ```

---

## 4. Airgap Wheelhouse & Python Virtualenv Issues

### A. Rebuilding the Virtualenv with Zero Internet (Venue Airgap Mode)
- If `.cache/wheelhouse/$(uname -s)-$(uname -m)/` is populated:
  ```bash
  python3 -m venv ~/.venvs/devfest-safe-agents-demo
  source ~/.venvs/devfest-safe-agents-demo/bin/activate
  bash scripts/cache-deps.sh install
  ```

### B. Refreshing the Wheelhouse Cache Before Travelling to the Venue
- While on fast Wi-Fi, run:
  ```bash
  bash scripts/cache-deps.sh download
  ```

---

## 5. Streamlit Visual Security Auditor (`:8501` & `:8080`) Issues

### A. Port `:8501` or `:8080` Busy / Auditor Not Updating
- Restart the persistent Auditor cleanly:
  ```bash
  bash scripts/auditor.sh restart
  bash scripts/auditor.sh status
  ```
- Clear previous run cards before going on stage:
  ```bash
  bash scripts/auditor.sh clear
  ```
