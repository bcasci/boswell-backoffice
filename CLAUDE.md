# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Fly.io infrastructure project that deploys an autonomous development operations platform. Four services run on a single machine (`backoffice-automation`, region `ewr`, shared-cpu-2x, 4GB RAM):

- **n8n** (port 5678) — workflow automation, event listener (webhooks, Gmail, schedules)
- **Dagu** (port 8080 internal) — workflow executor, runs `claude -p` subprocesses, web UI for observability
- **Caddy** (port 23000 external) — auth reverse proxy for Dagu dashboard (basic auth or GitHub OAuth)
- **PostgreSQL** + **Redis** — data services for boswell-hub (ActiveRecord, Sidekiq)

n8n listens for GitHub webhook events and enqueues Dagu DAGs via HTTP API. Dagu runs `claude -p` subprocesses that work on the managed repositories:

- `teamboswell/boswell-hub` → agent `boswell-hub-manager`
- `teamboswell/boswell-app` → agent `boswell-app-manager`

## Deploy

```bash
fly deploy                              # build + deploy (cached: <2min, cold: ~10min)
fly status -a backoffice-automation     # check machine status
fly logs -a backoffice-automation       # view logs
fly ssh console -a backoffice-automation -C "<cmd>"  # run command on server
```

Secrets are set via `fly secrets set KEY=value -a backoffice-automation`. Required: `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN`, `CADDY_AUTH_PASS`, `BOSWELL_HUB_MASTER_KEY`.

## Architecture

```text
Dockerfile          → builds image: Ubuntu 24.04 + n8n + Claude Code + Dagu + Caddy
entrypoint.sh       → starts all services, manages symlinks, seeds config
fly.toml            → Fly.io config, ports, env vars, VM size
workflows/*.json    → n8n workflow definitions (synced on every deploy)
dagu/config.yaml    → Dagu server config (auth, queues, paths)
dagu/dags/*.yaml    → Dagu DAG definitions (agent-dispatch, hello-world)
dagu/scripts/       → External scripts for DAG steps (Python, Bash)
scripts/            → helper scripts baked into image at /opt/scripts/
docs/plans/         → deployment plan and progress log
```

### Persistent Volume (`/data`, 10GB)

All state lives on `/data` and survives deploys:

```text
/data/n8n/           → n8n workflows, credentials, settings (~/.n8n symlink)
/data/dagu/          → Dagu config, DAGs, logs, execution history
/data/claude/        → Claude Code auth + settings (~/.claude symlink)
/data/agents/<name>/ → working directories for each agent
  repo/              → git clone (main branch)
  issues/issue-N/    → per-issue clones for implement jobs
/data/postgres/      → PostgreSQL data directory
/data/asdf/          → asdf Ruby installs
```

### Service Communication

- n8n → Dagu: `http://localhost:8080/api/v2/dags/{name}/enqueue` (no auth, internal)
- External → Dagu: `https://backoffice-automation.fly.dev:23000` (basic auth required)
- Caddy `@internal` matcher bypasses auth for localhost only (127.0.0.1, ::1)

## Dagu API (key endpoints)

```text
GET  /api/v1/dags                        → list all DAGs
GET  /api/v1/dags/{name}                 → get DAG status + latest run
POST /api/v2/dags/{name}/enqueue         → enqueue (respects queue concurrency)
POST /api/v2/dags/{name}/start           → start immediately (bypasses queue)
POST /api/v2/dags/{name}/stop            → stop running DAG
```

**Params format:** space-separated `KEY=value` pairs, NOT JSON.
**MESSAGE encoding:** base64-encode prompts to avoid space/quote issues in params.

## Pipeline Flow

```
GitHub webhook → n8n (intake) → Dagu enqueue → agent-dispatch DAG:
  1. post-start-comment   → posts "in progress" comment on GitHub issue
  2. setup-workspace      → git clone, branch checkout, CLAUDE.md guardrails
  3. run-claude           → claude -p "$MESSAGE" (runs to completion, no tmux)
  4. post-completion-comment → updates comment to "complete" with duration
  [on failure]            → updates comment to "failed"
```

## Critical Gotchas

**Dagu runs as `agent` user, not root.** Claude Code's `--dangerously-skip-permissions` is blocked for root. All agent directories must be `chown agent:agent`.

**Dagu v1.30.3 ignores config file `paths:` section.** Must use `DAGU_HOME=/data/dagu` env var and `--dags /data/dagu/dags` CLI flag explicitly.

**Dagu YAML uses camelCase.** Field names: `timeoutSec`, `handlerOn`, `continueOn` (NOT snake_case).

**CVE GHSA-6qr9-g2xw-cw92 (Dagu RCE).** Mitigated by localhost-only binding + Caddy auth proxy.

**n8n file access is restricted.** n8n 2.0+ defaults `N8N_RESTRICT_FILE_ACCESS_TO=~/.n8n-files`. We set it to `/tmp;/data` in `fly.toml` `[env]`. Semicolon-separated (colons don't work).

**n8n CLI import doesn't update running server.** Use `sync_workflows()` (hash-based sync on deploy) or modify the DB directly. See `workflows/CLAUDE.md` for details.

**Queue concurrency is 1.** Only one agent job runs at a time (VPS CPU/RAM constraint). Jobs queue via Dagu's `agent-work` queue.

## Skills

Review all available skills and invoke them when relevant.
