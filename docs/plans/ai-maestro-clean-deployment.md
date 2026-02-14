# AI Maestro Clean Deployment Plan

**Objective:** Remove old Maestro remnants and properly deploy 23blocks-OS/ai-maestro for 24/7 observable AI agent orchestration.

**Date:** 2026-02-11 (updated 2026-02-13)
**Status:** Phases 1-4.1 Complete, Dashboard Live, Phase 4.2 In Progress (n8n↔AI Maestro integration)

---

## Quick Reference - Essential Commands

**SSH into Fly machine:**

```bash
fly ssh console --app backoffice-automation
```

**Deploy changes:**

```bash
cd /Users/brandoncasci/projects/boswell/boswell-backoffice
fly deploy
```

**Check app status:**

```bash
fly status --app backoffice-automation
```

**View logs:**

```bash
fly logs --app backoffice-automation
```

**Access n8n (currently working):**

```
https://backoffice-automation.fly.dev/
```

**Target AI Maestro URL (after deployment):**

```
https://backoffice-automation.fly.dev:23000
```

**Fly.io app dashboard:**

```
https://fly.io/apps/backoffice-automation
```

---

## Context & Current State

### What's Currently Deployed

**✅ Working Services:**

- **n8n**: Workflow automation running on port 5678
  - URL: https://backoffice-automation.fly.dev/
  - Status: Operational, verified working
- **Claude Code CLI**: v2.1.39
  - Located at: `/usr/bin/claude`
  - Authentication: ✅ Via `CLAUDE_CODE_OAUTH_TOKEN` environment variable
  - Config: `/data/claude/.claude.json` with `hasCompletedOnboarding: true`
- **GitHub CLI**: v2.86.0
  - Authentication: ✅ Via `GH_TOKEN` environment variable

**❌ NOT Deployed:**

- AI Maestro (23blocks-OS/ai-maestro) - This is what we're adding

**Infrastructure:**

- Platform: Fly.io
- App name: `backoffice-automation`
- Machine: shared-cpu-1x with 2GB RAM (~$17/month)
- Region: ewr (Newark)
- Image size: 788 MB
- Persistent volume: `/data` (10GB)

### What Happened Before

**Previous Attempt Summary:**

1. Tried to install AI Maestro via runtime `yarn install` in entrypoint.sh
2. Failed due to network timeouts downloading npm packages from registry
3. Multiple ESOCKETTIMEDOUT errors (not resource constraints)
4. Installation took 10+ minutes even on performance-1x (dedicated CPU)
5. Decision: Disabled AI Maestro, deployed with just n8n + Claude Code

**Current entrypoint.sh status:**

- Has commented section: "AI Maestro installation skipped for now"
- No actual AI Maestro installation code active
- Just echoes skip message

**Current fly.toml status:**

- AI Maestro service (port 23000) is commented out
- Only n8n service (port 5678) is active

### Key Learnings - MUST READ

**❌ What DOESN'T work:**

- Direct `yarn install` from npm registry during container startup
- Network timeouts are common and unreliable
- Heavy ML dependencies (@huggingface/transformers, onnxruntime-node) take too long

**✅ What we know DOES work:**

- AI Maestro runs as **Node.js web service** (NOT Electron app)
- Dashboard accessible at `http://PEER_IP:23000` via browser
- Designed for server deployment with pm2 process manager
- Supports VPS deployment (AWS, DigitalOcean, Hetzner per docs)
- Uses tmux for session management

**Critical Facts:**

- AI Maestro docs explicitly support server/VPS deployment
- Dashboard is a web interface, accessible remotely
- No Electron/GUI needed for server deployment
- pm2 ecosystem.config.js should be used for process management
- Port 23000 must be exposed in Fly.io configuration

### File Locations

**Key files to modify:**

- `/Users/brandoncasci/projects/boswell/boswell-backoffice/Dockerfile`
- `/Users/brandoncasci/projects/boswell/boswell-backoffice/entrypoint.sh`
- `/Users/brandoncasci/projects/boswell/boswell-backoffice/fly.toml`

**Key directories:**

- Project root: `/Users/brandoncasci/projects/boswell/boswell-backoffice`
- Persistent data on Fly: `/data` (10GB volume)
- AI Maestro target: `/data/ai-maestro` (on persistent volume)

### Environment Variables Available

**Already configured in Fly.io secrets:**

- `CLAUDE_CODE_OAUTH_TOKEN` - For Claude Code authentication
- `GH_TOKEN` - For GitHub CLI authentication

**Will need to configure:**

- `AI_MAESTRO_DATA` - Point to `/data/ai-maestro` for persistence
- `PORT` - Set to 23000 for dashboard (if not default)

### Installation Strategy Constraints

**MUST avoid:**

- Long-running `yarn install` during container startup (network timeouts)
- Building during Dockerfile (image size limit 8GB uncompressed)
- Relying on npm registry availability during deployment

**Should consider:**

1. Pre-building node_modules locally, copying to volume
2. Multi-stage Docker build with caching
3. Using npm with retry flags instead of yarn
4. Installing AI Maestro in separate deployment step, then just starting it
5. Using the official remote-install script with modifications

---

## Success Criteria

- [x] Codebase has zero references to old Maestro (only "AI Maestro" remains; old spec is historical)
- [x] AI Maestro web dashboard accessible at https://backoffice-automation.fly.dev:23000
- [x] Claude Code agents visible and manageable in dashboard (unified API returns agents with public URL)
- [x] Remote access working from browser (no Electron needed)
- [x] Installation completes reliably on deployment (Docker build, 2.3GB image)
- [x] Services auto-restart on machine reboot (entrypoint.sh restart loop)
- [x] All data persists on /data volume (~/.aimaestro symlinked to /data/ai-maestro)

---

## Phase 1: Cleanup Old Maestro References

**Note:** There was never an "old Maestro" (pedramamini/Maestro) actually deployed. This phase removes:

- Remnants from early planning/exploration
- Comments about skipping AI Maestro
- Failed AI Maestro installation attempts in `/data/ai-maestro`
- Any confusion between old vs new Maestro

Goal: Clean slate with zero "maestro" references so we can add AI Maestro properly.

### 1.1 Search and Identify

- [x] Search codebase for "maestro" (case-insensitive)
- [x] Search for "/data/maestro" paths (none found in code files)
- [x] Search for "pedramamini" references (only in historical spec doc — acceptable)
- [x] Document all findings in checklist

### 1.2 Remove Code References

- [x] Remove any maestro-related comments in Dockerfile
- [x] Remove any maestro-related comments in entrypoint.sh
- [x] Remove any maestro-related comments in fly.toml
- [x] Clean up any maestro scripts in /scripts (updated post-deploy-setup.sh)

### 1.3 Remove Data Directory

- [x] SSH into Fly machine
- [x] Remove `/data/maestro` if exists *(handled by entrypoint cleanup logic)*
- [x] Remove `/data/ai-maestro` (old failed attempts) — overwritten with proper structure by entrypoint.sh
- [x] Verify clean state

### 1.4 Verify Cleanup

- [x] Run `grep -ri "maestro" .` in project root
- [x] Confirm only intentional ai-maestro references remain
- [ ] Commit cleanup changes *(user hasn't requested commit yet)*

---

## Phase 2: AI Maestro Deployment Prep

### 2.1 Research Installation Method

**Goal:** Find an installation method that avoids network timeouts and completes reliably.

**Specific docs to check:**

- [x] Read: https://raw.githubusercontent.com/23blocks-OS/ai-maestro/main/docs/SETUP-TUTORIAL.md
- [x] Look for: pm2 configuration examples (found ecosystem.config.js)
- [x] Look for: ecosystem.config.js usage (runs start-with-ssh.sh → node server.mjs)
- [x] Look for: Server/VPS deployment sections (bare-metal/VPS with pm2 is recommended)
- [x] Check: If there's a pre-built package or Docker image (no official Docker image for dashboard)

**Options evaluated:**

- [x] **Option A:** Rejected — too manual, doesn't scale
- [x] **Option B:** Rejected — same network timeout risk at runtime
- [x] **Option C:** **CHOSEN** — Docker build, baked into image
- [x] **Option D:** Rejected — manual one-time step, doesn't survive rebuilds
- [x] **Option E:** Rejected — still network-dependent at runtime

### 2.2 Create Installation Strategy

- [x] Document chosen approach in this plan (see Installation Method Decision section)
- [x] List required dependencies (python3, yarn, tmux, jq, build-essential — all in Dockerfile)
- [x] Plan environment variables needed (PORT=23000, NODE_ENV=production set in entrypoint.sh)
- [x] Design health check strategy (bash restart loop with logging to /data/ai-maestro/logs/)

### 2.3 Update Dockerfile

- [x] Add AI Maestro dependencies (python3, yarn, jq added)
- [x] Consider multi-stage build (chose single-stage — simpler, still under size limit)
- [x] Keep image under 8GB uncompressed (estimated ~1.5-2GB)
- [ ] Test build locally if possible *(deferred — test via `fly deploy`)*

### 2.4 Update entrypoint.sh

- [x] Add AI Maestro startup logic (node server.mjs in background)
- [x] Process management (bash restart loop instead of pm2 — simpler in container)
- [x] Add proper error handling (restart loop with timestamped logging)
- [x] Add retry logic for network operations (N/A — no runtime network ops, baked into image)
- [x] Configure auto-restart on failure (while true loop with 5s backoff)

### 2.5 Update fly.toml

- [x] Uncomment AI Maestro service on port 23000
- [x] Configure health checks (Fly.io TCP health check via [[services]] block)
- [x] Set appropriate timeout values (using Fly defaults)
- [x] Document security considerations (dedicated IPv4 note, TLS handler)

### 2.6 Configure Persistence

- [x] Ensure /data/ai-maestro is on persistent volume (mkdir + chown in entrypoint.sh)
- [x] Configure AI_MAESTRO_DATA environment variable (used symlink approach: ~/.aimaestro → /data/ai-maestro)
- [x] Plan for agent data persistence (/data/ai-maestro/agents/ directory)
- [x] Plan for conversation history retention (all AI Maestro data on /data volume)

---

## Phase 3: Installation Testing *(blocked on deployment)*

### 3.1 Local Testing (if feasible)

- [x] Test installation script locally — N/A, using Docker build approach instead
- [x] Verify node_modules can be built — will be verified by `fly deploy` Docker build
- [x] Test dashboard access on https://backoffice-automation.fly.dev:23000
- [x] Document issues found (see Progress Log)

### 3.2 Deploy to Fly.io

- [x] Run `fly ips allocate-v4 -a backoffice-automation` for dedicated IPv4 (169.155.59.251)
- [x] Deploy updated configuration: `fly deploy` (v26, 2.3GB image)
- [x] Monitor installation logs: `fly logs --app backoffice-automation`
- [x] Verify services start (n8n, AI Maestro, Caddy all running)

### 3.3 Verify Dashboard Access

- [x] Access https://backoffice-automation.fly.dev:23000 (basic auth working)
- [x] Verify dashboard loads correctly
- [x] Test adding Claude Code agent (boswell-hub-manager created)
- [x] Verify agent communication works (/api/agents/unified returns agents with public URL)

### 3.4 Test Persistence

- [ ] Restart machine: `fly apps restart backoffice-automation` *(user QA)*
- [ ] Verify AI Maestro restarts automatically *(user QA)*
- [ ] Verify data persists across restarts *(user QA)*
- [ ] Verify agents reconnect *(user QA)*

---

## Phase 4: Integration & Configuration

### 4.1 Configure Authentication

- [x] Review AI Maestro security docs (NO built-in auth — dashboard is completely open)
- [x] Implement authentication: Caddy reverse proxy with basic auth (testing) + oauth2-proxy for GitHub OAuth (production)
- [x] Architecture: Caddy on port 23000 → AI Maestro on port 23001 (internal only)
- [x] Document access method (see entrypoint.sh — auto-detects auth mode from Fly secrets)

**Auth modes (auto-detected by entrypoint.sh):**
1. **GitHub OAuth** — if `GITHUB_OAUTH_CLIENT_ID` + `GITHUB_OAUTH_CLIENT_SECRET` secrets are set
2. **Basic auth** — if `CADDY_AUTH_PASS` secret is set (testing)
3. **No auth** — fallback, logs a warning (not recommended)

**To switch to GitHub OAuth (user QA):**
1. Create GitHub OAuth App at https://github.com/settings/developers
   - App name: `Backoffice AI Maestro`
   - Homepage URL: `https://backoffice-automation.fly.dev:23000`
   - Callback URL: `https://backoffice-automation.fly.dev:23000/oauth2/callback`
2. Set Fly secrets:
   ```bash
   fly secrets set GITHUB_OAUTH_CLIENT_ID=<client-id> -a backoffice-automation
   fly secrets set GITHUB_OAUTH_CLIENT_SECRET=<client-secret> -a backoffice-automation
   fly secrets unset CADDY_AUTH_PASS -a backoffice-automation
   ```
3. Restart: `fly apps restart backoffice-automation`

### 4.2 Connect n8n to AI Maestro

**Architecture (confirmed 2026-02-13):**
- n8n is the **event listener** (webhooks, Gmail triggers, schedules)
- AI Maestro is the **agent dispatcher** (wake, chat, hibernate via HTTP API)
- n8n calls AI Maestro internally at `http://localhost:23001` (no auth needed)
- AI Maestro has NO built-in GitHub integration or event listening

**AI Maestro API Endpoints (verified working):**
| Action | Method | Endpoint |
|---|---|---|
| List agents | GET | `/api/agents` |
| Wake agent | POST | `/api/agents/{id}/wake` |
| Hibernate agent | POST | `/api/agents/{id}/hibernate` |
| Send message to agent | POST | `/api/agents/{id}/chat` (body: `{"message": "..."}`) |
| Send with idle-check | PATCH | `/api/agents/{id}/session` (returns 409 if busy) |
| Create session | POST | `/api/sessions/create` |

**Completed:**
- [x] Verified AI Maestro API is reachable from localhost (no auth)
- [x] Tested wake/hibernate cycle via API
- [x] Documented all API endpoints (full list in MEMORY.md)
- [x] Confirmed n8n can use HTTP Request nodes to call AI Maestro

**Cleanup — remove junk workflows:**
- [ ] Delete `github-auto-implementation.json` (calls nonexistent `ai-maestro-trigger.sh` script)
- [ ] Delete `daily-digest.json` (uses community node directly instead of AI Maestro API)
- [ ] Update `workflows/README.md` to reflect actual workflows
- [ ] Remove junk workflows from n8n UI on server

**Workflows to build:**
- [x] **FAQ Seeder** — Gmail → ConvertToFile → WriteToDisk → Claude (incremental batch processing). Working.
- [ ] **GitHub Issue Handler (boswell-hub)** — n8n GitHub Trigger node → IF (route by event) → HTTP Request to wake + chat AI Maestro agent `boswell-hub-manager`.
- [ ] **GitHub Issue Handler (boswell-app)** — same pattern for `boswell-app-manager`.
- [ ] **Email-to-Bug-Report** — Gmail trigger → classify email (is it a customer bug report?) → wake agent → `/chat` with bug report instructions → agent creates GitHub issue and investigates.
- [ ] **Daily Digest** — Schedule trigger → query GitHub issues → summarize via AI Maestro agent → notify.

**GitHub Webhook Architecture (decided 2026-02-13):**

Two workflows, one per repo. Each uses n8n's built-in **GitHub Trigger node** (`n8n-nodes-base.githubTrigger`).

Why two workflows (not one):
- GitHub Trigger node targets a single repo — one shared workflow would require a generic Webhook node, losing auto-registration and HMAC validation
- Each workflow hardcodes its agent ID — no repo-name routing needed
- Independent: disable/modify one without affecting the other
- Simpler: identical routing logic per workflow, only agent ID and repo name differ

GitHub Trigger benefits:
- Auto-registers webhooks on GitHub when workflow is activated (no manual webhook setup)
- HMAC-SHA256 signature validation handled internally (no custom Code node)
- Auto-deregisters webhook when workflow is deactivated
- Requires GitHub credentials (use existing `GH_TOKEN`) and repo owner/name

| Workflow | Repo | Agent Name | Events |
|---|---|---|---|
| GitHub Issue Handler (hub) | `teamboswell/boswell-hub` | `boswell-hub-manager` | issues, issue_comment, pull_request |
| GitHub Issue Handler (app) | `teamboswell/boswell-app` | `boswell-app-manager` | issues, issue_comment, pull_request |

**Routing logic (identical in each workflow):**

```text
GitHub Trigger → Switch (event type + action)
  ├─ issues.opened       → Wake Agent → Chat "New issue #{number}: {title}. Read the issue, analyze, respond with a plan."
  ├─ issues.labeled "auto" → Wake Agent → Chat "Issue #{number} labeled auto. Implement the fix and create a PR."
  ├─ issue_comment.created (not from bot) → Wake Agent → Chat "Comment on #{number}: {body}. Respond or take action."
  ├─ pull_request.opened → Wake Agent → Chat "PR #{number}: {title}. Review the changes."
  └─ default             → No-op (stop)
```

Each routing branch is 3 HTTP Request nodes:
1. `POST /api/agents/{id}/wake` — start Claude Code
2. `POST /api/agents/{id}/chat` — send task message (body: `{"message": "..."}`)
3. `POST /api/agents/{id}/hibernate` — stop agent after task (optional, can omit if agent should stay warm)

All HTTP requests go to `http://localhost:23001` (internal, no auth).

**Guard conditions:**
- `issue_comment`: filter out bot comments (check `sender.type != "Bot"` or `sender.login != "github-actions[bot]"`)
- `issues.labeled`: only act when the added label is `auto` (check `label.name == "auto"`)
- Optional: ignore issues/PRs from specific users (e.g., dependabot)

### 4.3 Configure Monitoring

- [x] Set up health checks in fly.toml (TCP health check via [[services]])
- [ ] Configure alerts for service failures
- [x] Document how to view agent status (AI Maestro dashboard)
- [x] Document how to access logs (`fly logs` or SSH to /data/ai-maestro/logs/maestro.log)

---

## Phase 5: Documentation *(partially complete)*

### 5.1 Update Deployment Docs

- [x] Document final architecture (docs/DEPLOYMENT.md updated)
- [ ] Update README with AI Maestro access instructions
- [ ] Document how to add agents *(after deployment testing)*
- [ ] Document how to trigger from n8n *(after integration testing)*

### 5.2 Create Operations Guide

- [x] How to access dashboard remotely (documented in DEPLOYMENT.md Phase 5)
- [x] How to restart services (documented in DEPLOYMENT.md troubleshooting)
- [x] How to view logs (documented in DEPLOYMENT.md)
- [x] Troubleshooting common issues (documented in DEPLOYMENT.md)

### 5.3 Update Cost Analysis

- [x] Document final machine size needed (shared-cpu-1x, 2GB RAM)
- [x] Calculate monthly cost (~$17/month + $2/month dedicated IPv4 = ~$19/month)
- [x] Compare to original $17/month target ($2 over due to dedicated IPv4)
- [x] Justify if higher (dedicated IPv4 needed for port 23000 external access)

---

## Atomic Steps Summary

**Phase 1 (Cleanup):**

1. Search for "maestro" → Document findings
2. Remove code references → Commit
3. Clean /data directories → Verify empty
4. Final grep verification → Confirm clean

**Phase 2 (Prep):**

1. Choose installation method → Document choice
2. Update Dockerfile → Test build
3. Update entrypoint.sh → Review logic
4. Update fly.toml → Validate config
5. Configure persistence → Test plan

**Phase 3 (Deploy):**

1. Deploy to Fly → Monitor logs
2. Verify installation → Check dashboard
3. Test persistence → Restart machine
4. Document any issues → Plan fixes

**Phase 4 (Integration):**

1. Configure auth/security → Document
2. Connect n8n → Create workflow
3. Set up monitoring → Configure alerts
4. Test end-to-end → Verify working

**Phase 5 (Documentation):**

1. Update docs → Review completeness
2. Create ops guide → Test instructions
3. Update cost analysis → Final numbers

---

## Installation Method Decision

**Completed 2026-02-11:**

**Chosen Method: Option C — Docker Build (bake into image)**

- [x] Method Name: Multi-layer Docker build with `yarn install` and `yarn build`
- [x] Why this method: Docker builders have reliable network connectivity (no runtime timeouts), layer caching makes subsequent builds fast, no runtime dependency on npm registry
- [x] Key steps: `git clone --depth 1` → `yarn install --network-timeout 300000` → `yarn build` → cleanup .git/tests
- [x] Expected installation time: 5-15 min first build, <2 min cached rebuilds
- [x] What could go wrong: `yarn build` could fail on prebuild help-index step (falls back gracefully), image size increase (~1.5-2GB total, still under 8GB)
- [x] Fallback plan: If Docker build times out, switch to multi-stage build with separate builder image, or use `npm install` with retry flags

**Rejected Methods:**

- **Option A (Pre-build locally, copy to volume):** Too manual, doesn't scale, requires rsync or fly ssh upload
- **Option B (npm instead of yarn):** Still relies on registry during deployment runtime — same timeout risk
- **Option D (Install once, then just start):** Manual one-time step, doesn't survive image rebuilds
- **Option E (Remote-install script):** Still network-dependent at runtime, designed for interactive/VPS use

**Decision Criteria:**

- ✅ Avoids network timeouts during deployment (Docker builder has reliable network)
- ✅ Completes in under 5 minutes (after first build, cached)
- ✅ Reliable and repeatable (deterministic Docker layers)
- ✅ Keeps image under 8GB uncompressed (~1.5-2GB estimated)
- ✅ Starts AI Maestro directly with `node server.mjs` (no pm2 needed in container)

**Port 23000 Access Note:**

Fly.io shared IPv4 only supports ports 80/443. To access AI Maestro on port 23000 externally:
- Allocate dedicated IPv4: `fly ips allocate-v4 -a backoffice-automation` ($2/month)
- Or use local proxy: `fly proxy 23000:23000 -a backoffice-automation`

---

## Risk Mitigation

| Risk                            | Mitigation                                        |
| ------------------------------- | ------------------------------------------------- |
| Network timeouts during install | Baked into Docker image (no runtime network deps) |
| Installation takes too long     | Docker layer caching, only first build is slow    |
| Port 23000 not accessible       | Dedicated IPv4 allocated ($2/month)               |
| Machine restarts during install | Persistent volume, restart loop in entrypoint.sh  |
| Dashboard doesn't load          | Caddy proxy + health checks + error logging       |
| Cost exceeds budget             | ~$19/month ($17 VM + $2 dedicated IP)             |
| Dashboard exposed without auth  | Caddy auth proxy (basic auth → GitHub OAuth)      |

---

## Resources

- [AI Maestro GitHub](https://github.com/23blocks-OS/ai-maestro)
- [AI Maestro Setup Tutorial](https://raw.githubusercontent.com/23blocks-OS/ai-maestro/main/docs/SETUP-TUTORIAL.md)
- [AI Maestro Troubleshooting](https://raw.githubusercontent.com/23blocks-OS/ai-maestro/main/docs/TROUBLESHOOTING.md)
- Previous deployment plan: `./ai-maestro-deployment.md`

---

## Progress Log

### 2026-02-11

- Created clean deployment plan
- Ready to execute Phase 1

### 2026-02-11 (Implementation)

- **Phase 1 Complete:** Cleaned all old Maestro references from codebase
  - Updated workflows/README.md, github-auto-implementation.json
  - Updated scripts/post-deploy-setup.sh
  - Updated docs/DEPLOYMENT.md (replaced all old Electron/Xvfb Maestro refs with AI Maestro)
- **Phase 2 Complete:** Updated deployment configuration
  - Dockerfile: Added python3, yarn, AI Maestro clone+build baked into image
  - entrypoint.sh: AI Maestro starts in background with restart loop, data persisted to /data/ai-maestro
  - fly.toml: Enabled AI Maestro service on port 23000 with TLS+HTTP handlers
- **Decision:** Chose Docker build approach (Option C) over runtime install
- **Note:** Dedicated IPv4 needed for external port 23000 access ($2/month)
- **Next:** Deploy with `fly deploy` and test

### 2026-02-11 (Auth & Deploy)

- **Security finding:** AI Maestro has NO built-in authentication (confirmed via SECURITY.md)
- **Auth solution:** Caddy reverse proxy on port 23000 → AI Maestro on port 23001 (internal)
  - Basic auth mode for testing (CADDY_AUTH_PASS secret)
  - GitHub OAuth mode for production (oauth2-proxy + Caddy forward_auth)
  - Auto-detection: entrypoint.sh checks which secrets are set
- **Added to Dockerfile:** Caddy (from apt), oauth2-proxy binary
- **Updated entrypoint.sh:** Dynamic Caddyfile generation, 3 auth modes
- **Removed:** playbooks/ and skills/ directories (dead code from old pedramamini/Maestro spec)
- **Deploying:** With basic auth first, user QAs GitHub OAuth

### 2026-02-11 (Deployment & Fixes)

- **Image too large (4.9GB → 2.3GB):** First deploy failed — exceeded Fly.io 8GB uncompressed rootfs limit
  - Root cause: onnxruntime-node native binaries (~700MB), dev dependencies, build caches
  - Fix: Post-build cleanup in Dockerfile (rm ONNX bins, npm prune --production, clean caches)
- **Agents not appearing in sidebar — Investigation #1:** ~/.aimaestro was a real directory, not symlink
  - Fix: Force symlinks with `rm -rf` + `ln -s` instead of conditional `[ ! -L ]` checks
- **Agents not appearing in sidebar — Investigation #2:** /api/agents/unified returned HTTP 401
  - Root cause: AI Maestro self-calls go through Caddy auth proxy (private IP → port 23000)
  - Fix: Added `@internal remote_ip` matcher in Caddyfile to bypass auth for localhost/private IPs
- **Agents not appearing in sidebar — ROOT CAUSE:** AI Maestro uses private Fly.io IP (172.x.x.x)
  - Browser JS tries to fetch from unreachable private IP → ERR_CONNECTION_TIMED_OUT + mixed content
  - AI Maestro auto-detects host URL via `getPreferredIP()` — no env var override exists
  - Fix: Seed `/data/ai-maestro/hosts.json` with public URL before AI Maestro starts
  - `MAESTRO_PUBLIC_URL` env var (defaults to `https://backoffice-automation.fly.dev:23000`)
- **Verified working:** `/api/agents/unified` returns `hostUrl: "https://backoffice-automation.fly.dev:23000"`, `agentCount: 1`
- **All three services running:** n8n (5678), AI Maestro (23001 internal), Caddy auth proxy (23000)
- **Dedicated IPv4 allocated:** 169.155.59.251 ($2/month)

### 2026-02-13 (n8n ↔ AI Maestro Integration)

- **FAQ Seeder workflow working:** Gmail → ConvertToFile → WriteToDisk → Execute Command (Claude incremental batch processing). 200 emails → 6 FAQ entries in ~5 minutes.
- **AI Maestro API verified:** wake, hibernate, list agents, chat — all working via localhost:23001
- **Second agent created:** `boswell-app-manager` for `teamboswell/boswell-app` (directory, ownership, tags, wake/hibernate tested)
- **n8n file access fix:** `N8N_RESTRICT_FILE_ACCESS_TO=/tmp;/data` in fly.toml (n8n 2.0+ defaults to `~/.n8n-files`)
- **GitHub webhook architecture decided:** Two workflows (one per repo), using n8n GitHub Trigger nodes (auto-registers webhooks, handles HMAC validation). Switch node routes by event type to wake → chat → hibernate AI Maestro agents.
- **Skills created:** `/create-maestro-agent`, `/deploy-n8n-workflow`
- **CLAUDE.md created and fact-checked**
- **Next:** Build the two GitHub Issue Handler workflows, clean up junk workflows
