# Backoffice Automation VPS — Fly.io Deployment Spec

## Overview

Deploy a single persistent Fly.io Machine as an autonomous development operations center. The machine runs n8n (workflow automation), Maestro (Claude Code agent orchestration), and Claude Code (AI coding agent) to enable:

**Inbound signals → GitHub issues → AI-driven development → pull requests → human review from phone.**

This is a prototype. Optimize for getting it working. Migration to Hetzner (~$7/mo vs ~$30/mo) comes later once the system is validated.

---

## Prerequisites (Human Has Already Prepared)

The following items are already configured and ready for use:

- ✅ **GitHub PAT token** — Classic token with `repo` and `workflow` scopes for `teamboswell` org
- ✅ **Claude Code OAuth token** — Generated via `claude setup-token` (from Max subscription)
- ✅ **SSH public key** — Available for server access configuration
- ✅ **Target repositories**:
  - `teamboswell/boswell-hub`
  - `teamboswell/boswell-app`

**These tokens are stored as Fly secrets** (set by human before/during deployment):
- `CLAUDE_CODE_OAUTH_TOKEN` — Claude Code authentication
- `GH_TOKEN` — GitHub CLI and n8n GitHub integration

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Fly.io Machine                        │
│                 (Ubuntu, shared-cpu-2x, 4GB RAM)         │
│                                                          │
│  ┌──────────┐   ┌──────────┐   ┌────────────────────┐   │
│  │   n8n    │──▶│ Maestro  │──▶│   Claude Code      │   │
│  │ (triage) │   │ (orchestr)│   │ (execute via Max)  │   │
│  └────┬─────┘   └────┬─────┘   └────────┬───────────┘   │
│       │              │                   │               │
│       ▼              ▼                   ▼               │
│  Webhooks      Playbooks +         Git worktrees         │
│  (email,       maestro-cli         TDD, branch,          │
│   Sentry,      (cron/trigger)      commit, PR            │
│   GitHub)                                                │
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │        /data (Fly Volume — persistent)           │    │
│  │  n8n DB, Maestro config, git repos, worktrees    │    │
│  └──────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
          │                              │
          ▼                              ▼
    GitHub (Issues, PRs)          Maestro Web UI
                                  (mobile via Cloudflare tunnel)
```

### Layer Responsibilities

| Layer         | Tool           | Role                                                                                        |
| ------------- | -------------- | ------------------------------------------------------------------------------------------- |
| Input/Routing | n8n            | Receive webhooks (email, Sentry, Slack, GitHub), classify, create GitHub issues with labels |
| Planning      | CCPM           | Decompose specs into parallel tasks via `/pm:` Claude Code commands                         |
| Orchestration | Maestro        | Manage Claude Code sessions, worktrees, playbooks, mobile monitoring                        |
| Execution     | Claude Code    | TDD, implement, test, commit, open PRs — authenticated via Max subscription                 |
| Monitoring    | Maestro Web UI | Browser-based remote control from phone via Cloudflare tunnel                               |
| Review        | GitHub Mobile  | Merge PRs from phone                                                                        |

---

## Authentication Model

### Claude Code Auth (CRITICAL — Security Sensitive)

Claude Code is authenticated via **Max subscription OAuth token**, not an API key. This means zero API costs.

**Setup flow:**

1. Run `claude setup-token` locally on your laptop — this generates an OAuth token
2. Store the token as a Fly.io secret: `fly secrets set CLAUDE_CODE_OAUTH_TOKEN=<token> -a backoffice-automation`
3. The token is available in the container's environment at runtime

**Security requirements:**

- The OAuth token **must never** be written to disk, logged, or exposed in Claude Code output
- Use Fly secrets (encrypted at rest, injected as env vars) — NOT environment variables in fly.toml
- Claude Code's `CLAUDE_CODE_OAUTH_TOKEN` env var is the documented headless auth method
- The entrypoint must NOT echo or log this variable
- If Claude Code reads `.env` files, ensure the token is not in any `.env` file on the volume
- Filter the token from any log aggregation

**Other auth tokens (also Fly secrets):**

- `GH_TOKEN` — GitHub PAT for `gh` CLI and n8n GitHub integration (scopes: `repo`, `issues`, `pull_requests`)
- n8n credentials (email IMAP/SMTP, Slack bot token, Sentry API token) are managed within n8n's encrypted credential store, not as env vars

---

## Machine Specification

### Fly.io Configuration

Use `fly launch` to generate the initial fly.toml and Dockerfile, then extend with the requirements below.

**Machine requirements:**

- **Size:** `shared-cpu-2x` with 4GB RAM (adjust if needed)
- **Region:** `bos` (Boston — closest to operator)
- **Always on:** `auto_stop_machines = "off"`, `min_machines_running = 1` — this is a persistent server, not request-driven
- **Primary HTTP service:** n8n on port 5678
- **SSH access:** Expose port 22 on an external port (e.g., 10022) for debugging and manual access

### Fly Volume

```bash
fly volumes create backoffice_data --region bos --size 20 -a backoffice-automation
```

20GB persistent NVMe. Mount at `/data`. Survives machine restarts. Daily snapshots (5-day retention default).

---

## What the Container Needs

The Dockerfile (generated by `fly launch`, then extended) must install:

### System packages

- `git`, `tmux`, `zsh`, `curl`, `wget`, `openssh-server`, `sudo`, `build-essential`
- `xvfb` and Electron dependencies (`libgtk-3-0`, `libnss3`, `libgbm1`, etc.) — Maestro is an Electron app that needs a virtual display on headless Linux
- `cloudflared` — for Maestro remote tunnel access

### Node.js & npm packages (global)

- Node.js 22.x
- `n8n` — workflow automation
- `@johnlindquist/n8n-nodes-claudecode` — n8n community node for Claude Code
- `@anthropic-ai/claude-code` — Claude Code CLI

### Other tools

- GitHub CLI (`gh`) — for issue/PR management from Claude Code and n8n
- Maestro desktop app — install from latest GitHub release (.deb or .AppImage from https://github.com/pedramamini/Maestro/releases). This is an Electron app, not an npm package.
- `maestro-cli` — headless CLI for running playbooks from cron/scripts (npm package, if available)

### Non-root user

- Create an `agent` user with passwordless sudo
- SSH key auth only (no password auth)
- Add this SSH public key to `/home/agent/.ssh/authorized_keys`:
  ```
  ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCwD9aC7Dwq3vZ6GZivD2YWW+HgLybuF7wnz8Pojgz8llyxO+rTJ+hpvMVe/ZsmYnSXEao/Jmfrta4xJagU0QlP1HpZav/a40Nt50V7cal+oynygM5UYkhA7XlgsHypj3uXdpxZ9JyNtiNuf3AG/rzylyHd2vm7gVQCDwY6zgw0FnxC4Y4Mb/S8Hq47SYmzm4twcVy/Yb8YtUoQhd//BlEVOROTkAHBP8VEYND5zSMjmsUFTdkT1RnCBNhU9JC2Kfp82skvzT0bF6GRjY5Vqchi9VEfYwtPlWNFxX1zXLsHkgAax8rcYfoX02H58SwYMwYURYMjag0uD21p/MsKDju5 brandon.casci@gmail.com
  ```

---

## What the Entrypoint Needs To Do

The entrypoint script starts all services when the container boots. It must:

1. **Ensure /data directory structure exists** — create subdirectories for n8n, maestro, repos, worktrees if missing. Set ownership to `agent` user.

2. **Symlink persistent directories** — n8n expects data at `~/.n8n`, so symlink to `/data/n8n`. Same pattern for any other tools that store state in home directory locations.

3. **Start Xvfb** — virtual framebuffer on display `:99` for Maestro's Electron process.

4. **Start SSH server** — for operator access.

5. **Start n8n** — background process, listening on port 5678. Set `N8N_USER_FOLDER=/data/n8n`.

6. **Start Maestro** — under Xvfb (`DISPLAY=:99`), with `--no-sandbox` flag. Maestro's built-in web server provides the remote UI.

7. **Stay alive** — wait on the n8n process (primary). If it dies, the container restarts.

**Security note for entrypoint:** Do NOT echo or log the `CLAUDE_CODE_OAUTH_TOKEN` or `GH_TOKEN` environment variables. Do not run `env` or `printenv` unfiltered.

---

## Data Persistence

Everything that must survive redeployment lives on the Fly Volume at `/data`:

| Path               | Contents                                                        |
| ------------------ | --------------------------------------------------------------- |
| `/data/n8n/`       | n8n database (SQLite), workflows, encrypted credentials, config |
| `/data/maestro/`   | Maestro config, session history, playbooks                      |
| `/data/repos/`     | Git clones of target projects (e.g., Boswell)                   |
| `/data/worktrees/` | Git worktrees for parallel agent execution                      |

Claude Code auth is handled via env var (Fly secret), NOT stored on the volume.

---

## Post-Deploy Setup (Manual, One-Time)

After the first `fly deploy`, SSH in to complete interactive setup:

### 1. Verify Claude Code auth

```bash
claude -p "echo hello"
# Should work without prompting for login — uses CLAUDE_CODE_OAUTH_TOKEN from Fly secret
```

### 2. Verify GitHub CLI auth

```bash
# GH_TOKEN env var (from Fly secret) automatically authenticates gh CLI
gh repo list teamboswell
# Should list repos without prompting for login
```

### 3. Clone target projects and install CCPM

```bash
cd /data/repos

# Clone both target repos
git clone https://github.com/teamboswell/boswell-hub.git
git clone https://github.com/teamboswell/boswell-app.git

# Set up CCPM in boswell-hub
cd boswell-hub
curl -fsSL https://automaze.io/ccpm/install | bash
claude -p "/pm:init"
claude -p "/context:create"

# Set up CCPM in boswell-app
cd ../boswell-app
curl -fsSL https://automaze.io/ccpm/install | bash
claude -p "/pm:init"
claude -p "/context:create"
```

CCPM installs `.claude/commands/pm/` with slash commands: `/pm:prd-new`, `/pm:prd-parse`, `/pm:epic-decompose`, `/pm:epic-sync`, `/pm:epic-start`, `/pm:epic-merge`.

### 4. Configure n8n

Access `https://backoffice-automation.fly.dev`:

- First-time setup wizard (create owner account)
- Install community node: Settings → Community Nodes → `@johnlindquist/n8n-nodes-claudecode`
- Set up credentials (GitHub PAT, email IMAP/SMTP, Slack, Sentry as needed)
- Create workflows (see templates below)

### 5. Set up Maestro remote access

Via Cloudflare tunnel (quick tunnel for testing, named tunnel for persistent access). Maestro also has built-in tunnel support in its settings.

### 6. Configure Maestro agents and playbooks

- Create agents pointed at `/data/repos/boswell-hub` and `/data/repos/boswell-app`
- Import or create playbooks
- Set Conductor Profile in Settings → General

---

## n8n Workflow Templates

### Email Triage

```
Email Trigger (IMAP) → Claude Code: classify as support/bug/feature/spam
  → bug:     GitHub Create Issue (label: bug)
  → feature: GitHub Create Issue (label: enhancement)
  → support: Claude Code draft reply → hold for approval
  → spam:    archive
```

### Sentry Error → Bug Fix

```
Webhook (Sentry) → extract error details → GitHub Create Issue (label: bug)
  → trigger Maestro fix-bug playbook with issue number
```

### GitHub Issue → Auto-Implementation

```
Webhook (GitHub issue labeled "auto") → extract issue number
  → trigger Maestro fix-bug playbook
```

### Feature Decomposition

```
Webhook (GitHub issue labeled "feature-spec")
  → Claude Code: /pm:prd-parse → /pm:epic-decompose → /pm:epic-sync → /pm:epic-start
```

### Daily Digest

```
Cron (8am) → GitHub: get open issues + PRs
  → Claude Code: summarize status → email/Slack
```

---

## Maestro Playbooks

Playbooks are markdown checklists that Maestro processes through Claude Code agents. Each checkbox becomes a task sent to Claude Code in batch mode (`claude -p`).

**fix-bug:** Read issue → identify affected files → write failing test → TDD fix → run test suite → commit → push → open PR

**implement-feature (small):** Read issue → review codebase context → write behavior specs (TDD) → implement → test → commit → push → open PR

**decompose-feature (large, uses CCPM):** Read spec issue → `/pm:prd-new` → `/pm:prd-parse` → `/pm:epic-decompose` → `/pm:epic-sync` → `/pm:epic-start` → monitor → `/pm:epic-merge`

**Architecture:** Playbook = which workflow to run. Skill (in `.claude/commands/`) = how to execute each step. Maestro = session lifecycle, worktrees, monitoring.

---

## Custom Claude Code Skills

These live in each project's `.claude/commands/` directory. Two essential ones:

**/fix-github-issue** — Reads a GitHub issue by number, creates a branch, writes a failing test, TDD fix, runs suite, commits, and opens a PR. Follows project CLAUDE.md standards.

**/implement-feature** — Same pattern but for new feature work. BDD/TDD approach, conventional commits, PR with issue link.

The exact prompt engineering for these skills should follow the project's CLAUDE.md and Jason Swett's behavior-driven testing approach.

---

## Implementation Responsibilities

### HUMAN MUST DO (Security-Sensitive)

**Before deployment:**
1. Run `claude setup-token` locally → copy the OAuth token
2. Create GitHub PAT at https://github.com/settings/tokens → copy the token
3. Set Fly secrets:
   ```bash
   fly secrets set CLAUDE_CODE_OAUTH_TOKEN=<token> -a backoffice-automation
   fly secrets set GH_TOKEN=<github-pat> -a backoffice-automation
   ```

**After deployment:**
1. Visit `https://backoffice-automation.fly.dev` for n8n first-time setup (create owner account)
2. Test Claude Code auth: `fly ssh console` then `claude -p "echo hello"`
3. Test GitHub CLI auth: `gh repo list teamboswell`

### AI CAN AUTOMATE

**Infrastructure generation:**
- Generate `Dockerfile` with all dependencies
- Generate `entrypoint.sh` with service startup logic
- Generate `fly.toml` with machine configuration
- Generate `.dockerignore`

**Post-deploy SSH automation:**
- Clone repos (`teamboswell/boswell-hub`, `teamboswell/boswell-app`)
- Install CCPM in each repo
- Initialize CCPM (`/pm:init`, `/context:create`)
- Verify installations

**Configuration files:**
- Create n8n workflow templates (JSON exports for import)
- Create Maestro playbooks (markdown files)
- Create custom Claude Code skills (`.claude/commands/` files)

---

## Deployment Steps

### Human runs locally (with tokens from prerequisites):

```bash
# 1. Create Fly app and volume
fly launch --no-deploy --name backoffice-automation --region bos
fly volumes create backoffice_data --region bos --size 20 -a backoffice-automation

# 2. Secrets are already set (done in prerequisites above)
```

### AI generates these files (implementation phase):

- `Dockerfile` (extended with all dependencies per "What the Container Needs")
- `entrypoint.sh` (service startup per "What the Entrypoint Needs To Do")
- `fly.toml` (machine config per "Machine Specification")
- `.dockerignore`

### Human deploys:

```bash
fly deploy -a backoffice-automation
```

### Verify deployment:

```bash
fly status -a backoffice-automation
fly logs -a backoffice-automation
```

### AI can SSH in to complete post-deploy setup:

```bash
fly ssh console -a backoffice-automation
# Then run commands from "Post-Deploy Setup" section
```

---

## Monitoring & Access

| What       | How                                           |
| ---------- | --------------------------------------------- |
| n8n UI     | `https://backoffice-automation.fly.dev`       |
| SSH        | `fly ssh console` or `ssh -p 10022 agent@...` |
| Maestro UI | Cloudflare tunnel URL                         |
| Logs       | `fly logs -a backoffice-automation`           |
| Status     | `fly status -a backoffice-automation`         |

---

## Migration Path to Hetzner

When ready to optimize cost:

1. `rsync /data/` from Fly machine to Hetzner Volume
2. Replicate the same tool install on Hetzner VPS (CX22, ~$7/mo) via cloud-init or manual setup
3. Set env vars for auth tokens
4. Same tools, same data, same workflows — just cheaper

The `/data` directory is fully portable. No vendor lock-in.

---

## Cost

| Item                                    | Monthly          |
| --------------------------------------- | ---------------- |
| Fly.io shared-cpu-2x, 4GB + 20GB volume | ~$28-33          |
| Claude Code (Max subscription)          | $0 incremental   |
| All software (n8n, Maestro, CCPM)       | $0 (open source) |
| **Post-migration (Hetzner)**            | **~$8-12**       |

---

## Known Risks

| Risk                               | Mitigation                                                                         |
| ---------------------------------- | ---------------------------------------------------------------------------------- |
| Maestro Electron on headless Linux | Xvfb virtual display. Fallback: maestro-cli headless only.                         |
| Maestro packaging (no .deb)        | Try .AppImage with `--appimage-extract`. Or build from source.                     |
| OAuth token expiry                 | Re-run `claude setup-token` locally, update Fly secret. Monitor with health check. |
| Single point of failure            | Daily volume snapshots. Restore to new machine in minutes.                         |
| n8n community node compat          | Pin version. Test after n8n upgrades.                                              |
| Auth token in logs                 | Never log env vars. Filter CLAUDE_CODE_OAUTH_TOKEN from all output.                |

---

## Open Questions (For Implementing AI to Resolve)

These questions should be investigated during implementation. Fallback solutions are provided.

1. **Maestro Linux packaging**
   - Check https://github.com/pedramamini/Maestro/releases for latest linux-amd64 .deb or .AppImage
   - If .AppImage: use `--appimage-extract` to extract and run
   - If neither: document in implementation notes and consider building from source
   - Fallback: Skip Maestro for MVP, use direct `claude -p` commands from n8n

2. **Maestro web server port**
   - Check https://docs.runmaestro.ai for default port
   - Common defaults to try: 3000, 3001, 8080
   - Document discovered port in `fly.toml` services section
   - Fallback: Use SSH tunnel to access if port is dynamic

3. **Maestro data directory**
   - Check Maestro CLI flags (`--help`) or docs for custom data path option
   - Try env vars: `MAESTRO_DATA_DIR`, `MAESTRO_HOME`
   - Fallback: Use symlinks from default location to `/data/maestro`

4. **maestro-cli availability**
   - Check if `maestro-cli` package exists on npm: `npm search maestro-cli`
   - If not available as separate package, CLI may be bundled in desktop app
   - Fallback: Invoke via desktop app binary with CLI flags, or use direct `claude -p` from n8n

5. **n8n community node install**
   - The package `@johnlindquist/n8n-nodes-claudecode` MUST be installed via n8n UI
   - Go to: Settings → Community Nodes → Install by name
   - Cannot be pre-installed via npm in Dockerfile (n8n security restriction)
   - Document in post-deploy steps (human must do this in n8n UI)

6. **OAuth token refresh cadence**
   - Monitor in production for expiration warnings
   - Set up health check that runs `claude -p "echo alive"` daily
   - If token expires, human must re-run `claude setup-token` locally and update Fly secret
   - Document expiration date when setting secret for tracking

---

## Reference Links

| Resource                  | URL                                                               |
| ------------------------- | ----------------------------------------------------------------- |
| Maestro                   | https://github.com/pedramamini/Maestro                            |
| Maestro Docs              | https://docs.runmaestro.ai                                        |
| Maestro Playbooks         | https://github.com/pedramamini/Maestro-Playbooks                  |
| CCPM                      | https://github.com/automazeio/ccpm                                |
| CCPM Commands             | https://github.com/automazeio/ccpm/blob/main/COMMANDS.md          |
| n8n-nodes-claudecode      | https://www.npmjs.com/package/@johnlindquist/n8n-nodes-claudecode |
| Claude Code Auth Docs     | https://code.claude.com/docs/en/authentication                    |
| Claude Code setup-token   | `claude setup-token` (generates OAuth token for headless/CI use)  |
| Fly.io Volumes            | https://fly.io/docs/volumes/overview/                             |
| Fly.io Secrets            | https://fly.io/docs/apps/secrets/                                 |
| Fly.io fly.toml Reference | https://fly.io/docs/reference/configuration/                      |
