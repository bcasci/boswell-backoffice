# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Fly.io infrastructure project that deploys an autonomous development operations platform. Three services run on a single machine (`backoffice-automation`, region `ewr`, shared-cpu-1x, 2GB RAM):

- **n8n** (port 5678) — workflow automation, event listener (webhooks, Gmail, schedules)
- **AI Maestro** (port 23001 internal) — agent orchestration dashboard, manages Claude Code instances via tmux
- **Caddy** (port 23000 external) — auth reverse proxy for AI Maestro (basic auth or GitHub OAuth)

n8n listens for events and dispatches work to AI Maestro agents via HTTP API. AI Maestro wakes Claude Code instances that work on the managed repositories:

- `teamboswell/boswell-hub` → agent `boswell-hub-manager`
- `teamboswell/boswell-app` → agent `boswell-app-manager`

## Deploy

```bash
fly deploy                              # build + deploy (cached: <2min, cold: ~10min)
fly status -a backoffice-automation     # check machine status
fly logs -a backoffice-automation       # view logs
fly ssh console -a backoffice-automation -C "<cmd>"  # run command on server
```

Secrets are set via `fly secrets set KEY=value -a backoffice-automation`. Required: `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN`, `CADDY_AUTH_PASS`.

## Architecture

```text
Dockerfile          → builds image: Ubuntu 24.04 + n8n + Claude Code + AI Maestro + Caddy + oauth2-proxy
entrypoint.sh       → starts all 3 services, manages symlinks, seeds config, fixes agent registry
fly.toml            → Fly.io config, ports, env vars, VM size
workflows/*.json    → n8n workflow definitions (seeded on first boot, see workflows/CLAUDE.md for editing procedures)
scripts/            → helper scripts baked into image at /opt/scripts/
docs/plans/         → deployment plan and progress log
```

### Persistent Volume (`/data`, 10GB)

All state lives on `/data` and survives deploys:

```text
/data/n8n/           → n8n workflows, credentials, settings (~/.n8n symlink)
/data/ai-maestro/    → agent registry, hosts.json, logs (~/.aimaestro symlink)
/data/claude/        → Claude Code auth + settings (~/.claude symlink)
/data/agents/<name>/ → working directories for each agent
/data/repos/         → cloned repositories
```

### Service Communication

- n8n → AI Maestro: `http://localhost:23001/api/...` (no auth, internal)
- External → AI Maestro: `https://backoffice-automation.fly.dev:23000` (auth required)
- Caddy `@internal` matcher bypasses auth for localhost/private IPs

## AI Maestro API (key endpoints)

```text
GET    /api/agents                    → list all agents
POST   /api/agents                    → create agent
POST   /api/agents/{id}/wake          → start Claude Code in tmux session
POST   /api/agents/{id}/hibernate     → stop agent
POST   /api/agents/{id}/chat          → send message to running agent
PATCH  /api/agents/{id}/session       → send command (409 if busy)
```

## Critical Gotchas

**AI Maestro runs as `agent` user, not root.** Claude Code's `--dangerously-skip-permissions` is blocked for root. All agent directories must be `chown agent:agent`.

**hosts.json must be seeded with public URL.** AI Maestro auto-detects private Fly.io IPs (172.x.x.x) which are unreachable from browsers. `entrypoint.sh` seeds `MAESTRO_PUBLIC_URL` on every boot.

**n8n file access is restricted.** n8n 2.0+ defaults `N8N_RESTRICT_FILE_ACCESS_TO=~/.n8n-files`. We set it to `/tmp;/data` in `fly.toml` `[env]`. Semicolon-separated (colons don't work).

**n8n CLI import doesn't update running server.** `n8n import:workflow` writes to SQLite only and does NOT publish — the running server ignores it. Do not use CLI import for updates. Instead, modify the DB directly with python3 + sqlite3 (update BOTH `workflow_entity` and `workflow_history`), then restart n8n. See `workflows/CLAUDE.md` for the full procedure and code template.

**Agent registry tags can't be updated via API.** PUT/PATCH on `/api/agents/{id}` doesn't reliably update tags. Edit `/data/ai-maestro/agents/registry.json` directly.

**`entrypoint.sh` fixes stale agent registry on every boot.** Replaces private IPs with public URL and ensures `--dangerously-skip-permissions` in programArgs.

## Skills

Review all available skills and invoke them when relevant.
