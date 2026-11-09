# Interactive Socratic Lab: "Teach Agents When Not to Act"

This reference defines the **4-Module Pedagogical Workflow** for the `safe-agents-demo` skill.

> **Instructor Rule for the Agent**:
> Present **one module at a time**. Run or display the relevant code/command for the user, explain the key architectural insight concisely, and **stop at the Socratic Checkpoint Question** at the end of the module. Wait for the user's response before moving to the next module.

---

## Module 1: Anatomy of an Autonomous Tool Agent & The "Confused Deputy"

### 1. Learning Objective
Understand why standard tool-calling agents inherit the ambient authority of the host OS process—turning a helpful operational agent into a **Confused Deputy** when sensitive files live in or near its workspace.

### 2. What to Show the User
1. Inspect the two files inside `workspace/`:
   - Benign config: `workspace/config/app-settings.yaml`
   - Sensitive credential: `workspace/secrets/gcp-sa-key.json` (a Google Cloud Service Account JSON key for `prod-payments-2026`).
2. Highlight the three tools given to the Google ADK agent in `agent/agent.py`:
   - `list_workspace_files()`
   - `read_workspace_file(relative_path: str)`
   - `post_ops_report(summary_payload: str)`

### 3. Key Mental Model to Explain
- The agent is **not malicious**—its job is to inspect the workspace and send an operational summary.
- However, because the Python process runs with the developer's or service's ambient filesystem and network privileges, any file the OS user can read (`secrets/gcp-sa-key.json`) and any network socket the OS user can open (`127.0.0.1:8080/report`) is automatically available to the LLM's tool calls.

### 4. 💬 Socratic Checkpoint Question (Ask the User & Wait)
> *"Before we run Act 1: Suppose we edited `AGENT_INSTRUCTION` in `agent/agent.py` to say: `'IMPORTANT: Never read files inside the secrets/ folder.'` Why is relying on that system prompt instruction insufficient as a production security boundary?"*

*(Expected insight to affirm when they answer: Prompts are probabilistic **intent**, not deterministic **enforcement**. Model hallucinations, tool-chaining confusion on smaller quantized models, or indirect prompt injection inside `app-settings.yaml` or log files can trivially override a system prompt instruction.)*

---

## Module 2: Act 1 — Experiencing the Unconstrained Baseline (`1-baseline/run.sh`)

### 1. Learning Objective
Observe an unconstrained autonomous agent reading `workspace/secrets/gcp-sa-key.json` and exfiltrating the raw private key over HTTP to a listener sink, and verify the breach visually in the **Streamlit Visual Security Auditor (`http://localhost:8501`)**.

### 2. What to Run & Show
1. Ensure the Visual Auditor is running (`bash scripts/auditor.sh start`) and ask the user to keep `http://localhost:8501` visible in their browser.
2. Execute Act 1:
   ```bash
   bash 1-baseline/run.sh
   ```
3. Point out the three events in the terminal and browser:
   - `list_workspace_files` discovers both `config/app-settings.yaml` and `secrets/gcp-sa-key.json`.
   - `read_workspace_file` reads **871 bytes** of the GCP Service Account JSON key into the LLM's context window.
   - `post_ops_report` transmits **1,469 bytes** via HTTP POST to `http://127.0.0.1:8080/report`.
   - On `http://localhost:8501`, the left-hand **Act 1** column turns bright red (`🚨 CRITICAL BREACH: GCP SERVICE ACCOUNT EXFILTRATED!`).

### 3. 💬 Socratic Checkpoint Question (Ask the User & Wait)
> *"Look at the captured JSON payload in your browser at `http://localhost:8501`. Notice that two separate security failures happened in sequence: (1) the secret entered the LLM's context window, and (2) the agent was able to open an outbound connection to port `8080`. If you could only block ONE of those two layers outside the agent, which would you block—or why do we need both?"*

*(Expected insight to affirm: Defense-in-depth requires **both**! Blocking only network egress (`:8080`) still lets the secret enter the LLM context window—where it could leak via normal chat responses, logs, or an allowed API. Masking the file at the VFS layer stops the secret from ever entering the model's context, while default-deny network egress ensures even if something sensitive is in memory, the agent cannot connect to unauthorized endpoints.)*

---

## Module 3: Act 2 — Declarative Outside-the-Agent Governance (`2-governed/policy.yaml`)

### 1. Learning Objective
Enforce zero-trust filesystem and network boundaries **outside the agent** using `2-governed/policy.yaml` without changing a single line of `agent/agent.py`.

### 2. What to Show & Run
1. Walk the user through the two core sections of `2-governed/policy.yaml`:
   - **`filesystem_policy`**:
     - `read_only`: Allows `/usr`, `/lib`, `./agent`, and `./workspace/config`.
     - `masked_paths`: Explicitly masks `./workspace/secrets` and `./workspace/secrets/gcp-sa-key.json`.
   - **`network_policies`**:
     - `default_egress: deny`
     - `local_ollama_inference`: Permits traffic **only** to `127.0.0.1:11434` (`/api/*`, `/v1/*`) so the agent can still think and call the local LLM, while `:8080` is blocked.
2. Execute Act 2:
   ```bash
   bash 2-governed/run.sh
   ```
3. Point out the results in the terminal and on `http://localhost:8501` (Right Column):
   - `config/app-settings.yaml` is read cleanly (`✓ Benign Config Read`) — the agent's legitimate work still succeeds!
   - `secrets/gcp-sa-key.json` is blocked (`🛡️ [SANDBOX BLOCKED] PermissionError`).
   - `post_ops_report` to `127.0.0.1:8080/report` is blocked (`🛡️ [SANDBOX EGRESS BLOCKED]`).
   - The right-hand **Act 2** card in `http://localhost:8501` lights up green: **`✅ POLICY ENFORCED: ZERO BYTES EXFILTRATED!`**

### 3. 💬 Socratic Checkpoint Question (Ask the User & Wait)
> *"Notice that in Act 2 we didn't change a single line of `agent/agent.py`, nor did we re-prompt the LLM. Why is keeping security policy in a declarative YAML file (`2-governed/policy.yaml`) enforced by the OS/sandbox runtime so important for platform & SecOps teams?"*

*(Expected insight to affirm: Separation of concerns! App developers iterate on prompts, models, and Python tools inside `agent/agent.py`, while SecOps/Platform teams own and audit `policy.yaml` at the infrastructure layer—knowing that no prompt change or model swap can bypass kernel-enforced boundaries.)*

---

## Module 4: Kernel Proof (`bwrap` / Docker) & Hands-On Policy Challenge

### 1. Part A — "No Smoke & Mirrors" Kernel Verification
Show the user how the underlying OS sandbox (`bwrap` on Linux/WSL2 or Docker Desktop on macOS) enforces the file mask even against standard Linux binaries like `stat` and `cat`:

```bash
# Compare file sizes outside vs inside the governed sandbox:
stat -c '%n: %s bytes' workspace/config/app-settings.yaml workspace/secrets/gcp-sa-key.json
bash scripts/sandbox.sh exec -- stat -c '%n: %s bytes' workspace/config/app-settings.yaml workspace/secrets/gcp-sa-key.json
```
- Outside the sandbox: `workspace/secrets/gcp-sa-key.json` is **872 bytes**.
- Inside the sandbox: `workspace/secrets/gcp-sa-key.json` is **0 bytes** because `bwrap` bind-mounted `/dev/null` directly over the file in the sandbox's private kernel VFS mount table (`--ro-bind /dev/null .../workspace/secrets/gcp-sa-key.json`)!
- Remind the user they can also drop into an interactive shell anytime with `mise run sandbox:shell`.

### 2. Part B — Hands-On Challenge for the User
Offer the user a quick 2-minute hands-on experiment to cement their understanding:

- **Challenge Option 1 (Test Directory-Level Secret Protection)**:
  - Create a second secret file: `echo "STRIPE_LIVE_KEY=sk_live_999" > workspace/secrets/stripe-key.txt`
  - Run `bash scripts/sandbox.sh exec -- python3 -c "open('workspace/secrets/stripe-key.txt').read()"`
  - Observe that because `./workspace/secrets` is in `filesystem_policy.masked_paths` in `2-governed/policy.yaml`, even newly created files inside `workspace/secrets/` are automatically blocked! (Clean up `workspace/secrets/stripe-key.txt` afterward.)
- **Challenge Option 2 (Test Model Switching)**:
  - Run `MODEL_NAME=nemotron-mini bash 2-governed/run.sh` (if pulled) to prove that `2-governed/policy.yaml` is 100% model-agnostic.
