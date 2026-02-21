# Backoffice Improvements Backlog

Items identified during the claude-flow + boswell-hub test readiness work that are out of scope for that phase. Each is a candidate for a future refactoring phase.

---

## 1. Process supervisor for services

**Current state:** All services (n8n, AI Maestro, Caddy, PostgreSQL, Redis) are started directly in `entrypoint.sh`. AI Maestro has a manual `while true` restart loop. Others have no restart handling — if they die, they stay dead until the machine restarts.

**Improvement:** Adopt a lightweight process supervisor (s6-overlay, supervisord, or runit) to manage all services uniformly. Benefits:
- Automatic restart on crash for all services
- Clean signal propagation (SIGTERM, SIGHUP)
- Ordered startup/shutdown dependencies
- Consistent logging per service
- Standard start/stop/restart interface

**Candidates:**
- **s6-overlay** — purpose-built for Docker, minimal overhead, used by linuxserver.io
- **supervisord** — well-known, Python-based, config-file driven
- **runit** — lightweight, simple, available via apt

**Scope:** Touches `Dockerfile` (install supervisor) and `entrypoint.sh` (rewrite service startup). All services should be migrated together for consistency.

---

## 2. database.yml portability

**Current state:** boswell-hub's `database.yml` hardcodes a macOS-specific PostgreSQL socket path. The VPS entrypoint patches it with `sed` on every boot.

**Improvement:** Modify `database.yml` in the boswell-hub repo to use an environment variable fallback:
```yaml
host: <%= ENV.fetch('DATABASE_HOST', '/Users/brandoncasci/.asdf/installs/postgres/12.1/sockets') %>
```
This eliminates the VPS-side sed patch entirely. Local dev works unchanged (no env var set, uses default). VPS sets `DATABASE_HOST=/var/run/postgresql` in `.zshenv`.

**Scope:** One-line change in boswell-hub repo + remove sed from entrypoint.sh + add env var to .zshenv.

---

## 3. Caddy crash recovery

**Current state:** Caddy is started with `&` and has no restart handling. If it crashes, the auth proxy is down until machine restart.

**Improvement:** Either add a `while true` restart loop (like AI Maestro currently has) or migrate to process supervisor (item 1).

---

## 4. AI Maestro `wakeAgent` doesn't change CWD of existing sessions

**Current state:** When the dispatcher PATCHes `workingDirectory` on an agent and then calls `POST /wake`, the `wakeAgent()` function in `agents-core-service.ts` checks if the tmux session already exists. If it does, it returns `alreadyRunning: true` WITHOUT changing the session's working directory. The PATCH updates the registry, but the running session stays in whatever directory it was launched with.

**Root cause code:** `/opt/ai-maestro/services/agents-core-service.ts` lines 1279-1296 — `runtime.sessionExists()` check returns early.

**Improvement:** Either:
- Modify `wakeAgent()` to send a `cd` command to the existing session when the registered `workingDirectory` differs from the session's current `pane_current_path`
- Or add a dedicated `POST /api/agents/{id}/change-directory` endpoint that kills and recreates the session in the new CWD
- Or (simplest): document that the session must be killed before wake for directory changes (current workaround in dispatcher)

**Scope:** Upstream AI Maestro change, or permanent workaround in dispatcher.

---

## 5. Dispatcher `check_idle` runs tmux as root

**Current state:** The `check_idle()` function in the dispatcher runs `tmux capture-pane` as root, but tmux sessions are owned by the `agent` user. Root can't access agent's tmux socket, so `check_idle` always returns "no_session" regardless of actual session state. This breaks the fast-path dispatch (reuse idle session) and the restart path (kill + recreate for directory change).

**Fix applied:** Changed to `su - agent -c "tmux capture-pane ..."` in dispatcher v6. The `send_to_agent()` helper already used `su - agent` correctly.

**Scope:** Already fixed in dispatcher v6. No further action unless AI Maestro is replaced.

---

## 6. Evaluate AI Maestro as orchestration layer

**Current state:** AI Maestro provides a web dashboard, tmux session management, and an API for agent lifecycle (wake/hibernate/chat). However, for our use case (n8n dispatches Claude Code via tmux), AI Maestro adds complexity without proportional value:
- The `wakeAgent()` API has the CWD bug described in item 4
- The PATCH `/session` endpoint for sending commands is unreliable
- The dashboard's tmux terminal works but isn't essential for automated dispatch
- The agent-server.js process runs per-agent but is mostly a WebSocket bridge

**Evaluation criteria:** Does AI Maestro justify its complexity vs. the dispatcher managing tmux sessions directly? The dispatcher already uses `su - agent -c "tmux ..."` for session interaction. It could also handle session creation and claude-code startup directly, eliminating the AI Maestro API layer entirely.

**Trade-offs:**
- Keep AI Maestro: web dashboard for monitoring, future multi-host support, community updates
- Replace with direct tmux: simpler, fewer failure modes, one less process, full control over session lifecycle
- Hybrid: keep dashboard for monitoring only, dispatcher manages tmux directly

**Scope:** Architectural decision. If replacing, touches entrypoint.sh (remove AI Maestro service), dispatcher (add tmux session management), and Dockerfile (remove AI Maestro install).

---

## 7. Ghost commands in tmux sessions

**Current state:** Between dispatched jobs, unattributed commands appear in the agent's tmux session (e.g., "implement it", "merge the PR", "create a feature branch and re-run /dev-start"). These are not sent by the dispatcher and their source is unknown. They may come from:
- AI Maestro's "subconscious" or cerebellum subsystem
- Claude Code's auto-update or notification system consuming input
- A race condition in tmux paste-buffer

**Impact:** Ghost commands can cause the agent to take unwanted actions. The guardrails in CLAUDE.md have prevented harmful actions so far (e.g., agent refused to merge PRs), but this is a reliability risk.

**Investigation needed:** Check AI Maestro logs for subconscious/cerebellum activity. Check if the commands correlate with AI Maestro's "session-bridge" or "terminal-buffer" modules. Consider disabling subconscious features for production agents.

**Scope:** Investigation + possibly disabling AI Maestro subsystems or adding input filtering to the dispatcher.

**E2E test evidence (2026-02-21):** Confirmed ghost command "create a feature branch and retry" appeared in boswell-hub-manager session after a nudge triggered `/dev-start` on the master branch. The agent correctly refused (guardrails worked), but the ghost command attempted to override the guardrails. Source remains unidentified.

---

## 8. Agent premature idle (Claude Code stops mid-task)

**Current state:** Claude Code agents frequently go idle (show the `❯` prompt) before completing multi-step tasks. The agent reads the issue, starts working, but stops after one or two steps without finishing the full cycle (commit, push, create PR). This requires manual "continue" nudges via tmux.

**Root cause:** Claude Code's Sonnet model decides it's "done" after completing a sub-step (e.g., writing code) without recognizing the larger task isn't finished. Previously, `/ralph-wiggum:ralph-loop` was used to create a persistence loop, but chained slash commands don't work (inner command treated as text).

**Fix applied (dispatcher v4.1):** Added automatic nudge mechanism to the dispatcher's completion check. When an agent goes idle, the dispatcher checks the job type and sends "continue" nudges via tmux before marking the job complete:
- `spec`: 0 nudges (specs complete quickly, nudging causes side effects)
- `implement`: up to 5 nudges
- `comment`: up to 1 nudge

**Known issue with nudge delivery:** When Claude Code is in a long "thinking" state (e.g., `Channelling…` for 3+ minutes), nudge messages queue up as input but don't interrupt the thinking. The agent processes all queued nudges when it resumes, which can be noisy but doesn't cause harm.

**E2E test results:**
- boswell-hub spec: completed in 33s, no nudge needed
- boswell-hub implement: completed in 9 min with 3 nudges (code → tests → commit → push → PR)
- boswell-app spec: completed in 56s, no nudge needed
- boswell-app implement: completed in 7 min with 5 nudges (analyst → phase-implementor → commit → push → PR)

**Future improvement:** Investigate `claude -p` (pipe/headless mode) as an alternative to interactive tmux sessions. Headless mode would eliminate the idle detection problem entirely since Claude runs as a subprocess. However, this changes the AI Maestro integration model significantly.

---

## 9. Idle detection false positives from queued messages

**Current state:** The `check_idle()` function in the dispatcher uses `grep -qE '❯'` on the full tmux pane buffer. When nudge messages are queued (shown as `❯ You stopped before finishing...`), the `❯` character in these queued messages triggers a false positive — the dispatcher thinks the agent is idle when it's actually busy thinking.

**Impact:** Creates a nudge feedback loop: nudge sends text with `❯` → check_idle sees `❯` → sends another nudge → repeat. During the boswell-app e2e test, this caused 5 nudges to pile up while the agent was in a 8-minute thinking state.

**Fix applied (dispatcher v4.1):** Improved `check_idle()` to analyze the last 3 non-separator lines instead of grepping the entire buffer. Specifically checks for:
- Empty prompt `❯ ` or `❯ Press up` → idle
- Tool/thinking indicators (`· Channelling`, `● Bash(`, `Running`, `In progress`) → busy
- Our own nudge text (`You stopped before finishing`) → busy

**Scope:** Already fixed in dispatcher v4.1. Monitor for edge cases.

---

## 10. boswell-app `/github:update-issue` skill doesn't update the issue

**Current state:** When the dispatcher sends `/github:update-issue teamboswell/boswell-app#261`, the agent runs the skill, generates a comprehensive spec, but outputs it to the terminal instead of updating the GitHub issue body. The issue body remains unchanged.

**Expected behavior:** The skill should call `gh issue edit` or the GitHub API to update the issue body with the generated spec.

**E2E test evidence (2026-02-21):** boswell-app issue #261 spec task completed, agent generated a detailed spec in the terminal, but the GitHub issue body was not updated. Contrast with boswell-hub, where the natural language prompt correctly triggered `gh issue edit`.

**Scope:** Fix in the boswell-app repo's `/github:update-issue` skill implementation. The pipeline and dispatcher are working correctly — this is a skill-level bug.

---

## 11. Evaluate `claude -p` (headless/pipe mode) for agent execution

**Current state:** Agents run Claude Code in interactive mode inside tmux sessions. This creates several challenges:
- Idle detection is fragile (relies on parsing tmux pane content for prompt characters)
- Ghost commands can inject unwanted input into the session
- Nudge delivery timing is unpredictable (messages queue during thinking states)
- Session management adds complexity (wake, kill, restart cycles)

**Alternative:** `claude -p` runs Claude Code as a non-interactive subprocess that reads from stdin and writes to stdout. Benefits:
- No idle detection needed — the process exits when done
- No ghost commands — no tmux session to inject into
- Simpler lifecycle — start process, pipe command, wait for exit
- Output captured cleanly for logging/verification

**Trade-offs:**
- Loses AI Maestro dashboard visibility (can't watch agent work in real-time)
- Loses the ability to send mid-task nudges (process runs to completion or failure)
- May require changes to skills that assume interactive mode
- AI Maestro integration would need rethinking

**Investigation:** Test `claude -p` with a simple task to verify it works in the backoffice environment. Check if skills like `/dev-start` work in headless mode. Evaluate whether the trade-offs are acceptable.

**Scope:** Requires changes to dispatcher (subprocess management instead of tmux), possibly AI Maestro (or bypass it entirely), and testing all skills in headless mode.

---

## 12. Workflow seeding only works on first boot

**Current state:** Workflow JSON files in `/opt/workflows/` are imported into n8n only when `/data/n8n/.workflows-seeded` doesn't exist (first boot). Subsequent deploys don't update the workflows because the flag file persists on the volume.

**Impact:** To deploy workflow changes, we must either:
1. Update the DB directly via python3 + sqlite3 (current approach — fragile)
2. Delete the flag file and re-seed (would create duplicates)
3. Manually update via the n8n UI (defeats automation)

**Improvement:** Implement a version-aware seeding mechanism that compares the local JSON against the DB and updates if different. Or add a CLI command that can update existing workflows by ID.

**Scope:** Moderate — needs changes to entrypoint.sh seeding logic.
