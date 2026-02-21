# Dagu Migration Plan

Replace AI Maestro with [Dagu](https://github.com/dagu-org/dagu) as the agent orchestration layer. Keep n8n for webhook intake only.

**End state:** GitHub issue events trigger n8n, n8n calls Dagu API, Dagu runs `claude -p` subprocesses, Dagu web UI provides observability.

**Date:** 2026-02-21

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Security: CVE GHSA-6qr9-g2xw-cw92](#security-cve-ghsa-6qr9-g2xw-cw92)
- [Alternatives Evaluated](#alternatives-evaluated)
- [Phase 0: Local Dagu validation](#phase-0-local-dagu-validation)
- [Phase 1: Remove AI Maestro](#phase-1-remove-ai-maestro)
- [Phase 2: Install Dagu (hello world)](#phase-2-install-dagu-hello-world)
- [Phase 3: GitHub webhook to Dagu dispatch](#phase-3-github-webhook-to-dagu-dispatch)
- [Phase 4: claude -p integration](#phase-4-claude--p-integration)
- [Phase 5: Cleanup and documentation](#phase-5-cleanup-and-documentation)
- [Contingency](#contingency)
- [Reference: Current Architecture](#reference-current-architecture)

---

## Architecture Overview

### Before (current)

```
GitHub webhook
  -> n8n GitHub Trigger (port 5678)
  -> n8n Code node (filter/route)
  -> n8n Execute Command (write JSON to /data/queue/<agent>/)
  -> n8n Schedule Trigger (60s poll)
  -> n8n Execute Command (500-line bash dispatcher)
     -> AI Maestro API (PATCH workDir, POST /wake, PATCH /session)
     -> tmux session (claude interactive)
     -> tmux capture-pane idle detection + nudge loop
```

Services: n8n + AI Maestro + Caddy + PostgreSQL + Redis

### After (target)

```
GitHub webhook
  -> n8n GitHub Trigger (port 5678)
  -> n8n Code node (filter/route)
  -> n8n HTTP Request node (POST to Dagu API /api/v1/dags/<dag>/enqueue)
  -> Dagu queue (max_concurrency: 1)
  -> Dagu DAG step: setup workspace (git clone, branch, guardrails)
  -> Dagu DAG step: claude -p (subprocess, exits when done)
  -> Dagu DAG step: post completion comment
```

Services: n8n + Dagu + Caddy + PostgreSQL + Redis

### What changes

| Component | Before | After |
|-----------|--------|-------|
| Orchestrator | AI Maestro (Node.js, ~1.5GB disk, tmux) | Dagu (Go binary, ~30MB) |
| Agent execution | `claude` interactive in tmux | `claude -p` subprocess (exits on completion) |
| Idle detection | tmux cursor position polling | Not needed (`claude -p` exits) |
| Nudging | tmux send-keys "continue" | Not needed (`claude -p` runs to completion) |
| Concurrency | Manual (one `.active` file per agent) | Dagu queue system (`max_concurrency: 1`) |
| Job queue | JSON files in /data/queue/ | Dagu built-in queue |
| Dispatch loop | 60s Schedule Trigger + bash | Dagu handles execution directly |
| Observability | AI Maestro dashboard (port 23000) | Dagu web UI (port 23000 via Caddy) |
| Workspace setup | Dispatcher bash (git clone, branch) | Dagu DAG step (same logic, cleaner) |

### What stays the same

- n8n webhook intake (GitHub Trigger + Code node) — modified to call Dagu API instead of writing queue files
- n8n email/FAQ workflows — untouched
- Issue workspace layout: `/data/agents/<name>/issues/issue-<N>/`
- Git clone per issue, `issue/{N}` branch naming
- CLAUDE.md guardrails injection
- GitHub status comments (started/completed)
- boswell-hub extras: master.key, caching-dev.txt, database.yml patch
- Fly.io infrastructure: same VM, same volume, same ports
- PostgreSQL, Redis — untouched

---

## Security: CVE GHSA-6qr9-g2xw-cw92

### The vulnerability

**Title:** Unauthenticated RCE via inline DAG spec in default configuration
**Severity:** Critical (CVSS 3.1)
**Published:** 2026-02-19
**Affected versions:** All through v1.30.3 (latest)
**Status:** Unpatched

Two issues:
1. Dagu ships with `auth.mode: none` by default. The `POST /api/v1/dag-runs` endpoint accepts arbitrary inline YAML and executes shell commands immediately — no authentication required.
2. Even with auth enabled, users with the `operator` role can submit arbitrary inline DAG specs.

### Our mitigation (defense in depth)

1. **Network isolation:** Dagu binds to `127.0.0.1:8080` only. Not reachable from outside the machine.
2. **Caddy auth proxy:** External access on port 23000 requires basic auth (same pattern as current AI Maestro proxy). Only one authenticated user (admin).
3. **Dagu auth enabled:** `auth.mode: basic` with username/password. Even if Caddy is bypassed, Dagu requires credentials.
4. **Fly.io network:** The machine is not on a shared network. No other tenants can reach localhost.
5. **n8n calls Dagu internally:** `http://127.0.0.1:8080/api/v1/...` — no external network traversal.

### Accepted risk

- The inline spec endpoint (`POST /api/v1/dag-runs`) cannot be disabled without patching the binary. We mitigate by not exposing it externally and requiring auth.
- If a future Dagu update patches the CVE, we should upgrade immediately.
- If the CVE becomes actively exploited in the wild, we can disable external Dagu UI access entirely (remove from Caddy config) since n8n calls it on localhost only.

### Monitoring

- Watch https://github.com/dagu-org/dagu/security/advisories for patches
- Watch https://github.com/dagu-org/dagu/releases for new versions

---

## Alternatives Evaluated

### coleam00/remote-agentic-coding-system

**Repository:** https://github.com/coleam00/remote-agentic-coding-system (324 stars, TypeScript)
**Verdict: Not viable for our use case.**

This is a chat interface to Claude Code (Telegram/@mentions), not an orchestration platform. It uses `@anthropic-ai/claude-agent-sdk` to run `claude -p` with `--resume` for multi-turn conversations.

Why it doesn't fit:
- **No multi-agent management.** One Node.js process with no concept of named agents or separate working directories.
- **No web UI.** Only health endpoints returning JSON. No dashboard, no log viewer.
- **In-memory queue.** Loses all queued jobs on restart. Our filesystem queue is more durable.
- **No n8n integration.** Only accepts Telegram messages and GitHub @mentions. We'd need to build REST endpoints.
- **No per-issue workspace isolation.** Uses a single cwd per conversation.
- **No scheduling or DAG workflow.** Every invocation is a single `query()` call.

The only transferable insight: the `claude-agent-sdk` usage pattern with `query()` + `resume: sessionId` provides a cleaner alternative to tmux sessions, confirming `claude -p` is the right direction.

### Cronicle

[Cronicle](https://github.com/jhuckaby/Cronicle) (4.2k stars, Node.js) remains a fallback if Dagu fails. Web UI, concurrency limits, REST API. Larger footprint (~200MB) but no known CVEs.

### Why Dagu wins

| Factor | Dagu | remote-agentic | Cronicle |
|--------|------|---------------|----------|
| Disk | ~30MB | ~200MB (node_modules) | ~200MB |
| RAM idle | ~20MB | ~100-200MB | ~100MB |
| Web UI | Yes | No | Yes |
| Queue system | Built-in | In-memory (lossy) | Built-in |
| DAG workflows | Yes | No | Yes |
| n8n trigger | HTTP API | Not supported | HTTP API |
| CVE risk | Known unpatched | None | Check |
| Local dev | `brew install dagu` | Docker Compose | npm install |

---

## Phase 0: Local Dagu validation

**Goal:** Validate Dagu DAG files, API format, and queue behavior locally on the dev machine before touching the server. This de-risks the entire migration.

### 0.1 Install Dagu locally

```bash
brew install dagu
dagu version  # expect v1.30.3
```

### 0.2 Create local test environment

```bash
# Isolated environment so it doesn't pollute ~/.config/dagu
export DAGU_HOME=/tmp/dagu-test
mkdir -p $DAGU_HOME/dags

# Start Dagu
dagu start-all
# Open http://localhost:8080
```

### 0.3 Validate DAG files

Copy the DAG YAML files we'll create (hello-world.yaml, agent-dispatch.yaml) into `$DAGU_HOME/dags/` and run:

```bash
dagu validate $DAGU_HOME/dags/hello-world.yaml
dagu validate $DAGU_HOME/dags/agent-dispatch.yaml
```

### 0.4 Test API trigger format

This is the exact call n8n will make. Test it locally:

```bash
# Trigger with params (the format n8n will use)
curl -s -X POST http://localhost:8080/api/v1/dags/agent-dispatch.yaml/enqueue \
  -H "Content-Type: application/json" \
  -d '{"params": "{\"AGENT_NAME\": \"test-agent\", \"REPO\": \"teamboswell/boswell-hub\", \"ISSUE_NUM\": \"99\", \"ACTION\": \"spec\", \"MESSAGE\": \"echo test\", \"NEEDS_WORKTREE\": \"false\"}"}'
```

Verify in the Dagu UI (http://localhost:8080) that:
- The job appears with correct parameters
- Steps execute in order
- Output is captured
- Parameters are accessible as `${AGENT_NAME}` etc.

### 0.5 Test queue concurrency

```bash
# Trigger two jobs rapidly
curl -s -X POST http://localhost:8080/api/v1/dags/agent-dispatch.yaml/enqueue \
  -H "Content-Type: application/json" \
  -d '{"params": "{\"AGENT_NAME\": \"agent-1\", \"ISSUE_NUM\": \"1\", \"ACTION\": \"test\"}"}'

curl -s -X POST http://localhost:8080/api/v1/dags/agent-dispatch.yaml/enqueue \
  -H "Content-Type: application/json" \
  -d '{"params": "{\"AGENT_NAME\": \"agent-2\", \"ISSUE_NUM\": \"2\", \"ACTION\": \"test\"}"}'
```

Verify: first runs immediately, second queues until first completes (if `max_concurrency: 1`).

### 0.6 Go/no-go gate

**STOP and pivot to contingency if ANY of these fail:**
- [ ] `dagu validate` rejects valid YAML syntax
- [ ] API `/enqueue` endpoint doesn't accept params in the documented format
- [ ] Queue concurrency doesn't work (both jobs run simultaneously despite `max_concurrency: 1`)
- [ ] Dagu crashes or uses >500MB RAM at idle
- [ ] The `params` JSON-string-in-JSON format is too fragile for n8n expression injection

**PROCEED if all pass.** The DAG files are validated, the API format is confirmed, and queue behavior is proven.

---

## Phase 1: Remove AI Maestro

**Goal:** Clean boot without AI Maestro. n8n + Caddy still run. Agent dispatch is offline (acceptable — we're rebuilding it).

### 1.1 Dockerfile changes

File: `Dockerfile`

Remove the AI Maestro clone/build block (lines 75-93):
```dockerfile
# DELETE THIS BLOCK:
# Clone and build AI Maestro (baked into image ...)
RUN git clone --depth 1 https://github.com/23blocks-OS/ai-maestro.git /opt/ai-maestro \
    && cd /opt/ai-maestro \
    && yarn install --network-timeout 300000 \
    ...
```

Remove `tmux` from apt-get install (line 8) — no longer needed. Keep all other packages.

Remove AI Maestro ownership line (line 118):
```dockerfile
# DELETE:
    && chown -R agent:agent /opt/ai-maestro \
```

Remove `/data/ai-maestro` from mkdir (line 116):
```dockerfile
# CHANGE:
RUN mkdir -p /data/n8n /data/repos /data/worktrees /data/asdf \
```

**Expected impact:** Image size drops by ~1.5GB (AI Maestro node_modules). Build time drops significantly.

### 1.2 entrypoint.sh changes

File: `entrypoint.sh`

Remove these functions entirely:
- `setup_ai_maestro_data()` (lines 249-267)
- `setup_ai_maestro_hosts()` (lines 269-293)
- `fix_agent_registry()` (lines 364-411)
- `start_ai_maestro()` (lines 609-624)

Remove from `setup_data_directories()`:
- `/data/ai-maestro` reference (it's not in the current mkdir, but check)

Remove from `main()`:
- `setup_ai_maestro_data` call
- `setup_ai_maestro_hosts` call
- `fix_agent_registry` call
- `start_ai_maestro` call
- AI Maestro line from the summary echo block

Update `setup_agent_working_directories()`:
- Remove the AI Maestro registry.json reading block (lines 300-314). Agent directories are still created by the `clone_repo_if_missing()` calls below it — those stay.

Remove `MAESTRO_PUBLIC_URL` variable (line 31).

Update `start_auth_proxy_*()` functions:
- Change `reverse_proxy 127.0.0.1:23001` to a placeholder or remove the Caddy config entirely (Phase 2 will reconfigure for Dagu).
- Simplest: make Caddy proxy to nothing on 23000 for now, or skip starting Caddy entirely in Phase 1.

Update header comment to remove AI Maestro references.

### 1.3 fly.toml changes

File: `fly.toml`

The `[[services]]` block for port 23000 (lines 27-33) can stay — we'll reuse it for Dagu's UI. Update the comment:
```toml
# Dagu dashboard on port 23000 (was AI Maestro)
```

### 1.4 Workflow changes

File: `workflows/agent-dispatcher.json`

The dispatcher workflow (`Agent Dispatcher`) references AI Maestro API (`http://localhost:23001/api/agents/...`) and tmux session management. In Phase 1, we can either:
- **Option A:** Deactivate the workflow (set `"active": false`) and leave the code as-is. The file stays in the repo as reference for Phase 4.
- **Option B:** Replace the Dispatch Work script with a no-op placeholder.

**Recommended: Option A.** The workflow is already `"active": false` in the JSON. The actual activation state is in n8n's database, but since the dispatcher won't work without AI Maestro anyway, it'll just error harmlessly if somehow triggered.

The intake workflows (`github-intake-hub-v2.json`, `github-intake-app-v2.json`) write to `/data/queue/` which the dispatcher reads. Without the dispatcher, jobs will queue up but not execute. This is acceptable for Phase 1.

### 1.5 Persistent volume cleanup

On the VPS, `/data/ai-maestro/` contains the agent registry, logs, and hosts.json. Options:
- **Leave it.** It's inert data on the persistent volume. Costs disk space but zero risk.
- **Remove it** post-deploy via: `fly ssh console -a backoffice-automation -C "rm -rf /data/ai-maestro"`

**Recommended: Leave it.** If we need to roll back, the registry is still there.

### 1.6 Deploy and verify

```bash
# Build and deploy
fly deploy

# Verify clean boot
fly logs -a backoffice-automation  # should show no AI Maestro errors

# Verify services
fly ssh console -a backoffice-automation -C "curl -s http://localhost:5678/healthz"  # n8n
fly ssh console -a backoffice-automation -C "pg_isready"  # PostgreSQL
fly ssh console -a backoffice-automation -C "redis-cli ping"  # Redis
```

### 1.7 Checklist

- [ ] Remove AI Maestro from Dockerfile (clone, build, chown, data dir)
- [ ] Remove tmux from Dockerfile apt-get
- [ ] Remove AI Maestro functions from entrypoint.sh
- [ ] Remove AI Maestro calls from main()
- [ ] Update/simplify Caddy config (Phase 1 placeholder)
- [ ] Update fly.toml comments
- [ ] Commit, push, deploy
- [ ] Verify clean boot via `fly logs`
- [ ] Verify n8n, PostgreSQL, Redis healthy

---

## Phase 2: Install Dagu (hello world)

**Goal:** Dagu running on the VPS, accessible via Caddy auth proxy on port 23000, with a hello-world DAG that can be triggered via API.

### 2.1 Add Dagu to Dockerfile

Dagu is a single Go binary. Add after the Caddy install block:

```dockerfile
# Install Dagu (workflow executor — single Go binary)
# Pin version for reproducibility. Check https://github.com/dagu-org/dagu/releases
ARG DAGU_VERSION=1.30.3
RUN wget -q "https://github.com/dagu-org/dagu/releases/download/v${DAGU_VERSION}/dagu_${DAGU_VERSION}_linux_amd64.tar.gz" \
    && tar xzf "dagu_${DAGU_VERSION}_linux_amd64.tar.gz" -C /usr/local/bin dagu \
    && rm "dagu_${DAGU_VERSION}_linux_amd64.tar.gz" \
    && chmod +x /usr/local/bin/dagu
```

Also add to versions.json for tracking:
```json
{
  "claude-code": "2.1.45",
  "n8n": "latest",
  "node": "22",
  "dagu": "1.30.3"
}
```

Add Dagu data directories to Dockerfile mkdir:
```dockerfile
RUN mkdir -p /data/n8n /data/repos /data/worktrees /data/asdf /data/dagu/dags /data/dagu/logs \
```

### 2.2 Dagu configuration

Create `dagu/config.yaml` in the repo (baked into image):

```yaml
# Dagu configuration — baked into Docker image, data on persistent volume
host: "127.0.0.1"
port: 8080

# All data on persistent volume
paths:
  dags_dir: "/data/dagu/dags"
  log_dir: "/data/dagu/logs"
  data_dir: "/data/dagu"

# Authentication (defense-in-depth, also behind Caddy auth)
auth:
  mode: "basic"
  basic:
    username: "admin"
    password: "${DAGU_AUTH_PASS}"

# Concurrency: max 1 claude -p at a time (VPS constraint)
queues:
  enabled: true
  config:
    - name: "agent-work"
      max_concurrency: 1

# Shell
default_shell: "/bin/bash"

# Timezone
tz: "America/New_York"

# Retention
hist_retention_days: 30
```

Copy config into image:
```dockerfile
COPY --chown=agent:agent dagu/ /opt/dagu/
```

### 2.3 Hello world DAG

Create `dagu/dags/hello-world.yaml`:

```yaml
name: hello-world
description: "Smoke test — verifies Dagu is working"

steps:
  - name: greet
    command: echo "Hello from Dagu on $(hostname) at $(date)"

  - name: check-env
    command: |
      echo "GH_TOKEN set: $([ -n "$GH_TOKEN" ] && echo yes || echo no)"
      echo "CLAUDE_CODE_OAUTH_TOKEN set: $([ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && echo yes || echo no)"
      echo "Working dir: $(pwd)"
      echo "User: $(whoami)"
```

### 2.4 entrypoint.sh: start Dagu

Add a `start_dagu()` function:

```bash
start_dagu() {
    echo "Starting Dagu on port 8080 (localhost only)..."

    # Ensure data directories exist
    mkdir -p /data/dagu/dags /data/dagu/logs

    # Copy baked-in DAGs to persistent volume (don't overwrite existing)
    cp -n /opt/dagu/dags/*.yaml /data/dagu/dags/ 2>/dev/null || true

    # Dagu config uses env var for auth password
    export DAGU_AUTH_PASS="${DAGU_AUTH_PASS:-$CADDY_AUTH_PASS}"

    # Substitute env vars in config and write to data dir
    envsubst < /opt/dagu/config.yaml > /data/dagu/config.yaml

    # Start Dagu as agent user (so claude -p inherits agent's env)
    (
        while true; do
            su - agent -c "dagu start-all --config /data/dagu/config.yaml" 2>&1 | \
                tee -a /data/dagu/logs/dagu.log
            echo "Dagu exited ($(date)), restarting in 5s..."
            sleep 5
        done
    ) &
    DAGU_PID=$!
}
```

Add `envsubst` to Dockerfile apt-get (it's in the `gettext-base` package):
```dockerfile
RUN apt-get update && apt-get install -y \
    ... \
    gettext-base \
```

Call `start_dagu` in `main()` where `start_ai_maestro` was.

### 2.5 Caddy config for Dagu UI

Update `start_auth_proxy_basic_auth()` to proxy to Dagu on port 8080 instead of AI Maestro on 23001:

```bash
start_auth_proxy_basic_auth() {
    echo "Starting auth proxy (basic auth) on port 23000..."
    CADDY_AUTH_USER="${CADDY_AUTH_USER:-admin}"
    CADDY_HASH=$(caddy hash-password --plaintext "$CADDY_AUTH_PASS")

    cat > /etc/caddy/Caddyfile <<CADDYEOF
:23000 {
    @internal remote_ip 127.0.0.1 ::1 172.16.0.0/12 10.0.0.0/8 192.168.0.0/16 fd00::/8
    handle @internal {
        reverse_proxy 127.0.0.1:8080
    }
    handle {
        basic_auth {
            $CADDY_AUTH_USER $CADDY_HASH
        }
        reverse_proxy 127.0.0.1:8080
    }
}
CADDYEOF

    AUTH_MODE="basic auth (user: $CADDY_AUTH_USER)"
}
```

Do the same for `start_auth_proxy_github_oauth()` and `start_auth_proxy_none()` — change `23001` to `8080`.

### 2.6 Fly secret for Dagu auth

```bash
# Reuse existing CADDY_AUTH_PASS, or set a separate one:
fly secrets set DAGU_AUTH_PASS="<password>" -a backoffice-automation
```

If `DAGU_AUTH_PASS` is not set, the entrypoint falls back to `CADDY_AUTH_PASS`. This means both Caddy and Dagu can share the same password, which is fine for a single-admin setup.

### 2.7 Deploy and verify

```bash
fly deploy

# Verify Dagu is running
fly ssh console -a backoffice-automation -C "curl -s http://localhost:8080/api/v1/health"

# Trigger hello-world DAG via API
fly ssh console -a backoffice-automation -C \
  "curl -s -X POST http://localhost:8080/api/v1/dags/hello-world.yaml/start \
   -u admin:\$DAGU_AUTH_PASS \
   -H 'Content-Type: application/json' \
   -d '{}'"

# Check Dagu UI externally
# https://backoffice-automation.fly.dev:23000 (basic auth)

# Verify hello-world ran and see output in Dagu UI
```

Also test triggering from n8n manually: create a temporary n8n workflow with an HTTP Request node that POSTs to `http://localhost:8080/api/v1/dags/hello-world.yaml/start`.

### 2.8 Checklist

- [ ] Add Dagu binary to Dockerfile (~30MB)
- [ ] Add `gettext-base` (envsubst) to Dockerfile
- [ ] Create `dagu/config.yaml` with localhost binding, auth, queue config
- [ ] Create `dagu/dags/hello-world.yaml`
- [ ] Add `start_dagu()` to entrypoint.sh
- [ ] Update Caddy configs to proxy 8080 instead of 23001
- [ ] Update versions.json with Dagu version
- [ ] Set DAGU_AUTH_PASS Fly secret (or verify CADDY_AUTH_PASS works)
- [ ] Deploy, verify health endpoint
- [ ] Trigger hello-world via API, verify in Dagu UI
- [ ] Test n8n -> Dagu API call

### 2.9 Go/no-go gate

**STOP and pivot to contingency if ANY of these are true:**
- [ ] Dagu fails to start on the VPS (binary incompatibility, missing libc, etc.)
- [ ] Dagu uses >500MB RAM at idle (leaves too little for claude -p)
- [ ] Caddy proxy to Dagu UI doesn't work (auth or routing issue)
- [ ] Health endpoint (`/api/v1/health`) unreachable from localhost
- [ ] Hello-world DAG fails to execute via API

**PROCEED to Phase 3** if Dagu is running, the UI is accessible, and you can trigger DAGs via API.

---

## Phase 3: GitHub webhook to Dagu dispatch

**Goal:** n8n intake workflows call Dagu API instead of writing queue files. Dagu receives job parameters and echoes them (no `claude -p` yet). Concurrency throttling verified.

### 3.1 Create the agent-dispatch DAG

Create `dagu/dags/agent-dispatch.yaml`:

```yaml
name: agent-dispatch
description: "Dispatch work to a Claude Code agent"
type: chain

params:
  AGENT_NAME: ""
  REPO: ""
  ISSUE_NUM: "0"
  ACTION: ""
  MESSAGE: ""
  NEEDS_WORKTREE: "false"

queue: "agent-work"

env:
  GH_TOKEN: "${GH_TOKEN}"
  CLAUDE_CODE_OAUTH_TOKEN: "${CLAUDE_CODE_OAUTH_TOKEN}"
  ASDF_DIR: "/opt/asdf"
  ASDF_DATA_DIR: "/data/asdf"
  PATH: "/data/asdf/shims:/opt/asdf/bin:/usr/local/bin:/usr/bin:/bin"
  LD_PRELOAD: "libjemalloc.so.2"

steps:
  - name: echo-params
    command: |
      echo "=== Agent Dispatch ==="
      echo "AGENT_NAME: ${AGENT_NAME}"
      echo "REPO: ${REPO}"
      echo "ISSUE_NUM: ${ISSUE_NUM}"
      echo "ACTION: ${ACTION}"
      echo "MESSAGE: ${MESSAGE}"
      echo "NEEDS_WORKTREE: ${NEEDS_WORKTREE}"
      echo "=== Will execute claude -p in Phase 4 ==="
```

### 3.2 Modify n8n intake workflows

The current intake workflows (hub and app) have three nodes:
1. **GitHub Trigger** — stays as-is
2. **Process Event** (Code node) — modify output format
3. **Handle Event** (Execute Command) — replace with HTTP Request to Dagu API

#### Process Event changes

The Code node currently outputs `{ type: "queue"|"cleanup", fileName, contentB64, agentName }`. Change it to output Dagu API parameters directly:

For **queue** events, output:
```json
{
  "type": "dispatch",
  "agentName": "boswell-hub-manager",
  "repo": "teamboswell/boswell-hub",
  "issueNum": 42,
  "action": "spec",
  "message": "/github:update-issue teamboswell/boswell-hub#42",
  "needsWorktree": false
}
```

For **cleanup** events, output:
```json
{
  "type": "cleanup",
  "agentName": "boswell-hub-manager",
  "issueNum": 42
}
```

The logic in the Code node stays mostly the same — just change the return format from base64-encoded queue files to structured Dagu parameters.

#### Handle Event changes

Replace the Execute Command node with two paths:

**Path 1: Dispatch (type === "dispatch")**
Replace with an HTTP Request node or Execute Command that calls Dagu API:

```bash
if [ "{{ $json.type }}" = "dispatch" ]; then
  curl -s -X POST "http://localhost:8080/api/v1/dags/agent-dispatch.yaml/enqueue" \
    -u "admin:${DAGU_AUTH_PASS}" \
    -H "Content-Type: application/json" \
    -d '{
      "params": "{\"AGENT_NAME\": \"{{ $json.agentName }}\", \"REPO\": \"{{ $json.repo }}\", \"ISSUE_NUM\": \"{{ $json.issueNum }}\", \"ACTION\": \"{{ $json.action }}\", \"MESSAGE\": \"{{ $json.message }}\", \"NEEDS_WORKTREE\": \"{{ $json.needsWorktree }}\"}"
    }'
  echo "Enqueued: {{ $json.agentName }} issue #{{ $json.issueNum }} ({{ $json.action }})"

elif [ "{{ $json.type }}" = "cleanup" ]; then
  AGENT_NAME="{{ $json.agentName }}"
  ISSUE_NUM="{{ $json.issueNum }}"
  WT_PATH="/data/agents/$AGENT_NAME/issues/issue-$ISSUE_NUM"
  if [ -n "$ISSUE_NUM" ] && [ -d "$WT_PATH" ]; then
    rm -rf "$WT_PATH"
    echo "Removed issue workspace: $WT_PATH"
  else
    echo "No workspace to clean (issue-$ISSUE_NUM)"
  fi
fi
```

Key difference: instead of writing a JSON file to `/data/queue/`, we call `POST /api/v1/dags/agent-dispatch.yaml/enqueue` with parameters. The `/enqueue` endpoint respects queue concurrency limits — if the queue is full, the job waits.

### 3.3 Dagu queue configuration

The `config.yaml` already defines the `agent-work` queue with `max_concurrency: 1`. The DAG file assigns itself to this queue via `queue: "agent-work"`.

**Behavior:**
- First job triggers immediately
- Second job waits in queue until first completes
- Jobs execute FIFO
- Dagu UI shows queued jobs as "queued" status

To allow 2 concurrent jobs (if VPS can handle it), change to `max_concurrency: 2` in config.yaml.

### 3.4 Make DAGU_AUTH_PASS available to n8n

n8n's Execute Command runs as root. The `DAGU_AUTH_PASS` Fly secret is available as an env var to the entrypoint, but n8n may not inherit it.

Options:
1. Set `DAGU_AUTH_PASS` in fly.toml `[env]` (not secrets — visible in config, but only used for localhost auth)
2. Use Dagu's `@internal` matcher approach — since n8n calls Dagu on localhost, we could set `permissions.run_dags: true` for unauthenticated localhost access
3. Write the password to a file that the Execute Command reads

**Recommended: Option 2** — configure Dagu to allow unauthenticated access from localhost for the API only. Since Dagu already binds to 127.0.0.1, this is safe. External access goes through Caddy which has its own auth.

Actually, Dagu doesn't have a per-source auth bypass. **Revised recommendation: set `auth.mode: none`** in Dagu config since it only binds to localhost. Caddy handles external auth. This matches the current AI Maestro pattern (no auth on internal port 23001).

Update `dagu/config.yaml`:
```yaml
auth:
  mode: "none"  # Safe: Dagu binds to localhost only. Caddy handles external auth.
```

This simplifies n8n -> Dagu calls (no auth header needed) and matches how AI Maestro worked internally.

### 3.5 Test plan

1. Deploy with echo-only DAG
2. Add `agent-spec` label to a test issue on boswell-hub
3. Verify n8n receives webhook, Code node processes it, Execute Command calls Dagu API
4. Verify Dagu UI shows the job queued/running/completed
5. Check Dagu job output shows echoed parameters
6. Add `agent-implement` labels to two issues simultaneously
7. Verify first runs immediately, second queues until first completes
8. Test cleanup: merge a PR with `issue/{N}` branch, verify workspace deleted

### 3.6 Checklist

- [ ] Create `dagu/dags/agent-dispatch.yaml` (echo-only)
- [ ] Modify intake Code nodes to output Dagu-compatible format
- [ ] Modify intake Handle Event to call Dagu API instead of writing queue files
- [ ] Decide on auth approach for n8n->Dagu (recommended: auth.mode none, localhost only)
- [ ] Deploy
- [ ] Test with real GitHub label events
- [ ] Verify concurrency: second job queues when first is running
- [ ] Verify Dagu UI shows job history and output

### 3.7 Go/no-go gate

**STOP and pivot to contingency if ANY of these are true:**
- [ ] n8n HTTP Request/Execute Command can't reach Dagu API on localhost
- [ ] Dagu `/enqueue` endpoint rejects the params format from n8n expressions
- [ ] Queue concurrency doesn't work on VPS (both jobs run simultaneously)
- [ ] GitHub webhook events are being silently dropped (check n8n execution log)
- [ ] Dagu job output doesn't capture parameters correctly

**PROCEED to Phase 4** if GitHub label events flow through n8n to Dagu, parameters appear correctly, and queuing works.

---

## Phase 4: claude -p integration

**Goal:** The agent-dispatch DAG sets up workspaces and runs `claude -p` to completion. GitHub status comments posted. Full E2E working.

### 4.1 Understanding `claude -p`

`claude -p "prompt"` runs Claude Code in print mode:
- Reads prompt from `-p` argument (or stdin)
- Executes autonomously (no interactive UI)
- Prints output to stdout
- Exits with code 0 on success, non-zero on failure
- Inherits working directory, env vars
- Needs: `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN` in environment
- Needs: `--dangerously-skip-permissions` flag for autonomous operation

### 4.2 Full agent-dispatch DAG

Replace the echo-only `agent-dispatch.yaml` with the full implementation:

```yaml
name: agent-dispatch
description: "Set up workspace and run claude -p for a GitHub issue"
type: chain

params:
  AGENT_NAME: ""
  REPO: ""
  ISSUE_NUM: "0"
  ACTION: ""
  MESSAGE: ""
  NEEDS_WORKTREE: "false"

queue: "agent-work"

env:
  GH_TOKEN: "${GH_TOKEN}"
  CLAUDE_CODE_OAUTH_TOKEN: "${CLAUDE_CODE_OAUTH_TOKEN}"
  ASDF_DIR: "/opt/asdf"
  ASDF_DATA_DIR: "/data/asdf"
  PATH: "/data/asdf/shims:/opt/asdf/bin:/usr/local/bin:/usr/bin:/bin"
  LD_PRELOAD: "libjemalloc.so.2"

steps:
  - name: post-start-comment
    script: |
      #!/bin/bash
      # Post "in progress" comment on GitHub issue, save comment ID for later update
      python3 << 'PYEOF'
      import json, urllib.request, os
      from datetime import datetime, timezone

      now = datetime.now(timezone.utc)
      agent = os.environ['AGENT_NAME']
      issue = os.environ['ISSUE_NUM']
      repo = os.environ['REPO']
      action = os.environ['ACTION']

      body = "\n".join([
          f"\U0001f916 **{agent}** is working on this issue.",
          "",
          f"**Task:** {action} \u00b7 **Issue:** #{issue}",
          f"**Started:** {now.strftime('%Y-%m-%d %H:%M UTC')}",
          "**Status:** \u23f3 In progress...",
      ])

      data = json.dumps({"body": body}).encode()
      req = urllib.request.Request(
          f"https://api.github.com/repos/{repo}/issues/{issue}/comments",
          data=data, method='POST',
          headers={
              'Authorization': f"token {os.environ.get('GH_TOKEN', '')}",
              'Accept': 'application/vnd.github+json',
              'Content-Type': 'application/json',
          }
      )
      resp = urllib.request.urlopen(req)
      comment = json.loads(resp.read())
      # Write comment ID to file for later steps
      with open('/tmp/dagu-comment-id', 'w') as f:
          f.write(str(comment['id']))
      with open('/tmp/dagu-start-time', 'w') as f:
          f.write(now.isoformat())
      print(f"STARTED: {agent} #{issue} ({action}) - comment {comment['id']}")
      PYEOF
    output: COMMENT_RESULT

  - name: setup-workspace
    script: |
      #!/bin/bash
      set -e
      AGENT_ROOT="/data/agents/${AGENT_NAME}"
      REPO_DIR="$AGENT_ROOT/repo"
      WT_PATH="$AGENT_ROOT/issues/issue-${ISSUE_NUM}"

      # Ensure safe.directory for git
      git config --global --add safe.directory '*' 2>/dev/null

      # Refresh main repo
      DEFAULT_BRANCH=$(git -C "$REPO_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
      [ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="master"
      git -C "$REPO_DIR" checkout "$DEFAULT_BRANCH" 2>/dev/null || true
      git -C "$REPO_DIR" fetch origin 2>&1
      git -C "$REPO_DIR" pull --ff-only 2>/dev/null || true

      WORK_DIR="$REPO_DIR"

      if [ "${NEEDS_WORKTREE}" = "true" ] || [ "${NEEDS_WORKTREE}" = "True" ]; then
        # Fresh clone per issue
        rm -rf "$WT_PATH"
        GITHUB_URL=$(git -C "$REPO_DIR" remote get-url origin)
        git clone "$REPO_DIR" "$WT_PATH" 2>&1
        git -C "$WT_PATH" remote set-url origin "$GITHUB_URL"
        git -C "$WT_PATH" fetch origin 2>&1

        # Checkout existing issue branch or create from default
        git -C "$WT_PATH" checkout "issue/${ISSUE_NUM}" 2>/dev/null || \
          git -C "$WT_PATH" checkout -b "issue/${ISSUE_NUM}" "origin/$DEFAULT_BRANCH" 2>&1

        # Verify we're on the right branch
        BRANCH_CHECK=$(git -C "$WT_PATH" rev-parse --abbrev-ref HEAD)
        if [ "$BRANCH_CHECK" = "master" ] || [ "$BRANCH_CHECK" = "main" ]; then
          echo "ERROR: branch checkout failed (still on $BRANCH_CHECK)"
          exit 1
        fi

        # Clean Claude Code work cache
        rm -rf "$WT_PATH/.claude/work" 2>/dev/null

        # Set gh default repo
        git -C "$WT_PATH" config --local gh.default-repo "${REPO}" 2>/dev/null
        cd "$WT_PATH" && gh repo set-default "${REPO}" 2>/dev/null || true

        # Inject CLAUDE.md guardrails
        cat >> "$WT_PATH/CLAUDE.md" << GUARDRAILS

      ## Agent Guardrails (auto-injected by dispatcher)

      - **NEVER create or switch branches.** Work on whatever branch you are on when the session starts.
      - **If you are on main or master, STOP.** Do not proceed - report the error and exit.
      - **NEVER merge pull requests.** Only create PRs and leave them for human review.
      - **NEVER close or resolve issues.** Only reference them in PR descriptions.
      - **This repository is: ${REPO}.** Always use \`--repo ${REPO}\` with gh CLI commands, or omit --repo to use the configured default.
      GUARDRAILS

        # boswell-hub extras
        if [ "${AGENT_NAME}" = "boswell-hub-manager" ] && [ -n "${BOSWELL_HUB_MASTER_KEY}" ]; then
          echo -n "${BOSWELL_HUB_MASTER_KEY}" > "$WT_PATH/config/master.key"
          chmod 600 "$WT_PATH/config/master.key"
          mkdir -p "$WT_PATH/tmp"
          touch "$WT_PATH/tmp/caching-dev.txt"
          sed -i 's|/Users/brandoncasci/.asdf/installs/postgres/12.1/sockets|/var/run/postgresql|g' "$WT_PATH/config/database.yml"
        fi

        chown -R agent:agent "$WT_PATH"
        WORK_DIR="$WT_PATH"

      elif [ "${NEEDS_WORKTREE}" = "if_exists" ] && [ -d "$WT_PATH" ]; then
        WORK_DIR="$WT_PATH"
      fi

      # Write work dir to file for next step
      echo "$WORK_DIR" > /tmp/dagu-work-dir
      echo "WORKSPACE: $WORK_DIR (branch: $(git -C "$WORK_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null))"

  - name: run-claude
    script: |
      #!/bin/bash
      set -e
      WORK_DIR=$(cat /tmp/dagu-work-dir)
      cd "$WORK_DIR"

      echo "Running claude -p in $WORK_DIR"
      echo "Prompt: ${MESSAGE}"

      # Run claude in print mode — exits when done
      claude -p "${MESSAGE}" --dangerously-skip-permissions 2>&1

      echo "claude -p completed with exit code $?"
    timeout_sec: 3600
    retry_policy:
      limit: 0

  - name: post-completion-comment
    script: |
      #!/bin/bash
      python3 << 'PYEOF'
      import json, urllib.request, os
      from datetime import datetime, timezone

      comment_id = open('/tmp/dagu-comment-id').read().strip()
      start_str = open('/tmp/dagu-start-time').read().strip()
      start = datetime.fromisoformat(start_str)
      now = datetime.now(timezone.utc)
      dur = int((now - start).total_seconds() / 60)

      agent = os.environ['AGENT_NAME']
      issue = os.environ['ISSUE_NUM']
      repo = os.environ['REPO']
      action = os.environ['ACTION']

      body = "\n".join([
          f"\U0001f916 **{agent}** finished working on this issue.",
          "",
          f"**Task:** {action} \u00b7 **Issue:** #{issue}",
          f"**Started:** {start.strftime('%Y-%m-%d %H:%M UTC')}",
          f"**Completed:** {now.strftime('%Y-%m-%d %H:%M UTC')} \u00b7 Duration: {dur}m",
          "**Status:** \u2705 Complete",
      ])

      data = json.dumps({"body": body}).encode()
      req = urllib.request.Request(
          f"https://api.github.com/repos/{repo}/issues/comments/{comment_id}",
          data=data, method='PATCH',
          headers={
              'Authorization': f"token {os.environ.get('GH_TOKEN', '')}",
              'Accept': 'application/vnd.github+json',
              'Content-Type': 'application/json',
          }
      )
      urllib.request.urlopen(req)
      print(f"COMPLETE: {agent} #{issue} ({action}) - {dur}m")
      PYEOF
    continue_on:
      failure: true

handler_on:
  failure:
    command: |
      python3 << 'PYEOF'
      import json, urllib.request, os
      from datetime import datetime, timezone

      comment_file = '/tmp/dagu-comment-id'
      if not os.path.exists(comment_file):
          print("No comment to update (start comment was never posted)")
          exit(0)

      comment_id = open(comment_file).read().strip()
      start_str = open('/tmp/dagu-start-time').read().strip()
      start = datetime.fromisoformat(start_str)
      now = datetime.now(timezone.utc)
      dur = int((now - start).total_seconds() / 60)

      agent = os.environ.get('AGENT_NAME', 'unknown')
      issue = os.environ.get('ISSUE_NUM', '?')
      repo = os.environ.get('REPO', '')
      action = os.environ.get('ACTION', '')

      body = "\n".join([
          f"\U0001f916 **{agent}** encountered an error on this issue.",
          "",
          f"**Task:** {action} \u00b7 **Issue:** #{issue}",
          f"**Started:** {start.strftime('%Y-%m-%d %H:%M UTC')}",
          f"**Failed:** {now.strftime('%Y-%m-%d %H:%M UTC')} \u00b7 Duration: {dur}m",
          "**Status:** \u274c Failed (check Dagu UI for logs)",
      ])

      data = json.dumps({"body": body}).encode()
      req = urllib.request.Request(
          f"https://api.github.com/repos/{repo}/issues/comments/{comment_id}",
          data=data, method='PATCH',
          headers={
              'Authorization': f"token {os.environ.get('GH_TOKEN', '')}",
              'Accept': 'application/vnd.github+json',
              'Content-Type': 'application/json',
          }
      )
      try:
          urllib.request.urlopen(req)
          print(f"FAILED: {agent} #{issue} ({action}) - {dur}m")
      except Exception as e:
          print(f"ERROR updating failure comment: {e}")
      PYEOF
```

### 4.3 Key differences from current dispatcher

| Feature | Current (AI Maestro + tmux) | New (Dagu + claude -p) |
|---------|---------------------------|----------------------|
| Idle detection | tmux cursor position polling every 60s | Not needed — `claude -p` exits when done |
| Nudging | tmux send-keys "continue" (5 nudges max) | Not needed — `claude -p` runs to completion |
| Session reuse | Reuse idle tmux session if same dir | No session reuse — each job is a fresh subprocess |
| Working directory | PATCH API before wake, tmux cd races | Set `cd` before `claude -p` in script |
| Stuck detection | >2h timer in dispatcher | `timeout_sec: 3600` in DAG step |
| Start/complete comments | Python heredocs in bash | Same pattern, cleaner as DAG steps |
| Queue management | JSON files + 60s poll loop | Dagu built-in queue with concurrency limit |

### 4.4 Prompt construction

The current dispatcher sends slash commands to the interactive Claude session:
- **spec (boswell-hub):** Natural language "Read issue and write spec..."
- **spec (boswell-app):** `/github:update-issue teamboswell/boswell-app#42`
- **implement:** `/dev-start teamboswell/boswell-hub#42`
- **comment:** Free-form text from the `@agent` mention

For `claude -p`, slash commands like `/dev-start` may not work the same way. We need natural language equivalents:

```
# spec (boswell-hub)
claude -p "Read issue teamboswell/boswell-hub#42 and write an outcome-oriented spec. Update the issue body with the spec. At the bottom, preserve the original issue text inside a collapsed details tag. Above that details tag, add an HTML comment that says ORIGINAL_ISSUE_TEXT and instructs AI to ignore everything below it."

# spec (boswell-app)
claude -p "Read issue teamboswell/boswell-app#42 using \`gh issue view 42 --repo teamboswell/boswell-app\`. Write a detailed specification. Update the issue body with the spec using \`gh issue edit\`."

# implement
claude -p "Implement the requirements in issue teamboswell/boswell-hub#42. Read the issue spec, write code, run tests, commit, push, and create a pull request. Reference the issue in the PR description with 'Fixes #42'."

# comment
claude -p "<user's @agent instruction>"
```

These prompts should be constructed in the n8n Code node (Process Event) and passed as the `MESSAGE` parameter to the Dagu DAG.

**Important:** Test these prompts manually first with `claude -p` on the VPS before automating.

### 4.5 Running as agent user

Dagu runs as the `agent` user (via `su - agent` in entrypoint). The `agent` user's `.zshenv` provides `CLAUDE_CODE_OAUTH_TOKEN` and `GH_TOKEN`. However, `claude -p` in a DAG step inherits Dagu's environment, which may or may not source `.zshenv`.

To be safe, the DAG explicitly sets `GH_TOKEN` and `CLAUDE_CODE_OAUTH_TOKEN` in its `env:` block. These come from Dagu's process environment, which inherits from `su - agent` (which sources `.zshenv`).

Verify this during testing:
```bash
fly ssh console -a backoffice-automation -C \
  "su - agent -c 'dagu start-all --config /data/dagu/config.yaml &' && \
   sleep 5 && \
   curl -s -X POST http://localhost:8080/api/v1/dags/hello-world.yaml/start -H 'Content-Type: application/json' -d '{}'"
```

### 4.6 BOSWELL_HUB_MASTER_KEY

The setup-workspace step needs `BOSWELL_HUB_MASTER_KEY` for boswell-hub issue clones. This is a Fly secret, available to the entrypoint process. It needs to reach the Dagu DAG environment.

Options:
1. Pass it as a Dagu env var in config.yaml: `BOSWELL_HUB_MASTER_KEY: "${BOSWELL_HUB_MASTER_KEY}"`
2. Write it to a file that the DAG reads
3. The `su - agent` in entrypoint doesn't inherit Fly secrets — only what's in `.zshenv`

**Solution:** Add `BOSWELL_HUB_MASTER_KEY` to `/home/agent/.zshenv` in `setup_agent_secrets()`:
```bash
export BOSWELL_HUB_MASTER_KEY="$BOSWELL_HUB_MASTER_KEY"
```

And add to the DAG's `env:` block:
```yaml
env:
  BOSWELL_HUB_MASTER_KEY: "${BOSWELL_HUB_MASTER_KEY}"
```

### 4.7 E2E test plan

1. **Spec test (boswell-hub):** Add `agent-spec` label to a test issue
   - Verify: n8n receives webhook, calls Dagu API
   - Verify: Dagu queues job, runs setup-workspace, runs claude -p
   - Verify: Issue body updated with spec
   - Verify: GitHub comment shows started -> completed
   - Verify: Dagu UI shows successful run with logs

2. **Implement test (boswell-app):** Add `agent-implement` label to a test issue with spec
   - Verify: Workspace created with issue branch
   - Verify: claude -p creates PR
   - Verify: PR references the issue

3. **Concurrency test:** Label two issues simultaneously
   - Verify: First runs immediately, second queues
   - Verify: Second starts after first completes

4. **Failure test:** Label an issue that will cause claude -p to fail
   - Verify: GitHub comment updated to "Failed"
   - Verify: Dagu UI shows failure with error logs

### 4.8 Checklist

- [ ] Write full `agent-dispatch.yaml` DAG with all steps
- [ ] Update n8n intake Code nodes with claude -p compatible prompts
- [ ] Add BOSWELL_HUB_MASTER_KEY to agent .zshenv and DAG env
- [ ] Test claude -p manually on VPS first
- [ ] Deploy
- [ ] E2E test: spec on boswell-hub
- [ ] E2E test: implement on boswell-app
- [ ] E2E test: concurrency (two jobs, verify queuing)
- [ ] E2E test: failure case
- [ ] Compare timing vs old dispatcher (expect faster: no 35s wake wait, no 60s poll delay)

### 4.9 Go/no-go gate

**STOP and investigate if ANY of these are true:**
- [ ] `claude -p` doesn't inherit env vars (GH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN) when run by Dagu
- [ ] `claude -p` prompts don't produce equivalent results to interactive slash commands
- [ ] Workspace setup (git clone, branch checkout) fails under Dagu's execution context
- [ ] GitHub status comments aren't posted (API auth issue from Dagu subprocess)
- [ ] Jobs consistently timeout (>60 min) — may indicate `claude -p` is hanging

**Note:** Unlike Phase 0-3 gates, Phase 4 failures are likely fixable (prompt tuning, env var passing) without abandoning Dagu. Only pivot to contingency if the issue is fundamental to Dagu's execution model.

---

## Phase 5: Cleanup and documentation

**Goal:** Remove dead code, update docs, record learnings.

### 5.1 Remove old dispatcher

- Delete `workflows/agent-dispatcher.json` from the repo (the n8n workflow file)
- Deactivate the Agent Dispatcher workflow in n8n's database if it's still active
- The Schedule Trigger + Execute Command pattern is fully replaced by Dagu

### 5.2 Remove queue infrastructure

- Remove `/data/queue/` creation from `setup_data_directories()` in entrypoint.sh
- On VPS: `rm -rf /data/queue/` (or leave it — inert data)

### 5.3 Remove tmux

- Already removed from Dockerfile in Phase 1
- Verify no remaining references in entrypoint.sh or scripts

### 5.4 Update CLAUDE.md

Update the project's `CLAUDE.md` to reflect the new architecture:

- Replace "AI Maestro" references with "Dagu"
- Update service list: n8n (5678) + Dagu (8080 internal, 23000 via Caddy) + Caddy + PostgreSQL + Redis
- Update the architecture diagram
- Update the "Critical Gotchas" section
- Remove AI Maestro API documentation
- Add Dagu API quick reference
- Document the CVE mitigation

### 5.5 Update auto-memory files

Update `memory/MEMORY.md`:
- Replace AI Maestro references with Dagu
- Remove dispatcher v4.1 section
- Remove AI Maestro dispatch gotchas
- Add Dagu section with API patterns, config location, queue behavior
- Update architecture section

### 5.6 New Caddyfile documentation

Document the Caddy config pattern for Dagu:
```
:23000 → basic_auth → reverse_proxy 127.0.0.1:8080 (Dagu)
localhost bypass: @internal matcher skips auth for internal calls
```

### 5.7 Checklist

- [ ] Delete `workflows/agent-dispatcher.json`
- [ ] Remove queue directory setup from entrypoint.sh
- [ ] Update CLAUDE.md with new architecture
- [ ] Update memory/MEMORY.md
- [ ] Remove stale memory files (ai-maestro-agent-creation.md, etc.)
- [ ] Verify no tmux references remain
- [ ] Final deploy and full E2E test
- [ ] Clean up /data/queue/ on VPS (optional)

---

## Contingency

### If Dagu doesn't work out

Reasons this could happen:
- Dagu binary too large for 8GB rootfs limit (unlikely — it's ~30MB)
- Dagu consumes too much RAM at idle (unlikely — Go binary, should be minimal)
- Queue system doesn't work as documented
- CVE is actively exploited before a patch is available
- API is unreliable or poorly documented

### Fallback: minimal Python service

If Dagu fails, the simplest replacement is a lightweight Python HTTP service:

```
/opt/scripts/dispatch-service.py
  - Flask/bottle on port 8080
  - POST /dispatch with JSON params
  - Spawns claude -p as subprocess
  - Tracks active jobs in /data/dispatch/state.json
  - Max 1 concurrent, queues excess in-memory
  - No web UI (use logs for observability)
```

This loses the Dagu web UI but keeps the `claude -p` subprocess model. The n8n intake workflows would be identical (just calling a different HTTP endpoint).

### Fallback: Cronicle

[Cronicle](https://github.com/jhuckaby/Cronicle) (4.2k stars, Node.js) is a more full-featured alternative:
- Web UI with job history
- Built-in concurrency limits
- REST API for triggering jobs
- Already runs on Node.js (no new runtime)
- Larger footprint than Dagu (~200MB)

### Decision criteria

| Factor | Dagu | Python service | Cronicle |
|--------|------|----------------|----------|
| Disk size | ~30MB | ~0 (Python already installed) | ~200MB |
| RAM at idle | ~20MB | ~10MB | ~100MB |
| Web UI | Yes | No | Yes |
| Queue system | Built-in | Manual | Built-in |
| Complexity | Low | Very low | Medium |
| CVE risk | Known unpatched | None | Check |

---

## Reference: Current Architecture

### Files that change

| File | Phase | Change |
|------|-------|--------|
| `Dockerfile` | 1, 2 | Remove AI Maestro, add Dagu binary |
| `entrypoint.sh` | 1, 2 | Remove AI Maestro functions, add Dagu startup |
| `fly.toml` | 1 | Update comments |
| `versions.json` | 2 | Add Dagu version |
| `workflows/agent-dispatcher.json` | 5 | Delete |
| `workflows/github-intake-hub-v2.json` | 3 | Modify Handle Event to call Dagu API |
| `workflows/github-intake-app-v2.json` | 3 | Modify Handle Event to call Dagu API |
| `CLAUDE.md` | 5 | Update architecture docs |
| `dagu/config.yaml` | 2 | New file — Dagu configuration |
| `dagu/dags/hello-world.yaml` | 2 | New file — smoke test DAG |
| `dagu/dags/agent-dispatch.yaml` | 3, 4 | New file — main dispatch DAG |

### Files that don't change

| File | Reason |
|------|--------|
| `workflows/faq-seeder.json` | Email/FAQ workflow — out of scope |
| `scripts/build-faq.sh` | FAQ script — out of scope |
| PostgreSQL/Redis setup in entrypoint.sh | Not related to agent orchestration |
| Ruby/asdf bootstrap | Not related to agent orchestration |

### Key ports

| Port | Service | Binding | External access |
|------|---------|---------|----------------|
| 5678 | n8n | 0.0.0.0 | Yes (Fly HTTP service, ports 80/443) |
| 8080 | Dagu | 127.0.0.1 | No (localhost only) |
| 23000 | Caddy | 0.0.0.0 | Yes (Fly TCP service, dedicated IPv4) |
| 5432 | PostgreSQL | socket | No |
| 6379 | Redis | 127.0.0.1 | No |

### Dagu API quick reference

```bash
# Health check
GET /api/v1/health

# List DAGs
GET /api/v2/dags

# Trigger DAG (fire and forget — bypasses queue)
POST /api/v2/dags/{name}/start
  Body: {"params": "KEY=value KEY2=value2"}

# Trigger DAG (queue-controlled — respects max_concurrency)
POST /api/v2/dags/{name}/enqueue
  Body: {"params": "KEY=value KEY2=value2"}

# List DAG runs
GET /api/v2/dags/{name}/dag-runs
```

**Validated locally (Phase 0):** Params are space-separated `KEY=value` pairs, NOT JSON-in-JSON. Use the **v2 `/enqueue`** endpoint for queue-controlled execution. The v1 API `POST /api/v1/dags/{name}` with `{"action": "start"}` also works but doesn't queue.
