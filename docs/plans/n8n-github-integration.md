# n8n ↔ GitHub ↔ AI Maestro Integration Plan

**Objective:** Connect GitHub events to AI Maestro agents via n8n so that issues, comments, and PRs automatically trigger Claude Code to analyze, respond, and implement.

**Date:** 2026-02-13
**Status:** Phase A, B & C Complete — Phase D/E future
**Implementation approach:** JSON construction + CLI import (no UI needed). Simplified to Code node + Execute Command architecture — avoids complex IF/Switch node parameter formats.
**Prereqs complete:** AI Maestro deployed, two agents registered, API verified (see `ai-maestro-clean-deployment.md`)

---

## Architecture Decision

### Workflows

Three n8n workflows: two **intake** (one per repo) and one **dispatcher** (shared).

| Workflow            | Type     | Trigger        | Purpose                                    |
| ------------------- | -------- | -------------- | ------------------------------------------ |
| GitHub Intake (hub) | Intake   | GitHub Trigger | Gate check → write job to filesystem queue |
| GitHub Intake (app) | Intake   | GitHub Trigger | Gate check → write job to filesystem queue |
| Agent Dispatcher    | Dispatch | Schedule (60s) | Poll queues → check agent idle → send work |

Why intake and dispatcher are separate:

- Intake is fast and stateless — receives webhook, validates gate, writes file, done
- Dispatcher polls on a schedule — no stuck executions, no retry loops, predictable
- Filesystem queue decouples event arrival from agent availability
- Multiple issues can queue up while agent is busy — processed FIFO when agent becomes idle

Why two intake workflows (not one):

- GitHub Trigger node targets one repo — shared workflow would need generic Webhook (loses auto-registration + HMAC validation)
- Each hardcodes its agent queue directory — no repo routing needed

### Gate & Labels

Compound `agent-*` labels control the pipeline. The `agent-` prefix is the gate — any label starting with `agent-` opts the issue into automation AND specifies the action in one step.

| Label             | Purpose                                              | Who adds it |
| ----------------- | ---------------------------------------------------- | ----------- |
| `agent-spec`      | Agent writes an outcome-oriented spec from the draft | Human       |
| `agent-implement` | Agent implements the spec/issue                      | Human       |

No standalone `agent` label needed. One label = one action, gate included.

PRs are ungated — `pull_request.opened` always queues.

Comment trigger: `@agent <instruction>` in any issue or PR comment. The `@agent` mention is the gate; everything after it is the operative instruction passed to the agent.

Guards:

- `issues.labeled`: only act when `label.name` starts with `agent-` → route by suffix
- `issue_comment`: skip if comment body does not contain `@agent`, or `sender.type == "Bot"`

### Issue Lifecycle

1. Human creates issue with rough outline
2. Human adds `agent-spec` → agent writes spec (edits body or posts comment)
3. Human comments `@agent <instruction>` → agent follows the instruction (refine spec, clarify, etc.)
4. Human adds `agent-implement` → agent implements from spec, creates PR
5. PR opened → agent notified (PR branch)

Re-triggerable: remove and re-add a label to re-run that step.

### Intake Flow

```text
GitHub Trigger (issues, issue_comment, pull_request)
  │
  ├─ issues.labeled (label.name starts with "agent-")
  │    ├─ "agent-spec"      → Write spec job to /data/queue/<agent>/
  │    ├─ "agent-implement" → Write implement job to /data/queue/<agent>/
  │    └─ other agent-*     → (future actions, same pattern)
  │
  ├─ issue_comment.created (body contains "@agent" + sender not bot)
  │    → Extract instruction after "@agent" → Write job to /data/queue/<agent>/
  │
  ├─ pull_request.opened (no label gate)
  │    → Write PR job to /data/queue/<agent>/
  │
  ├─ pull_request.closed + merged (no label gate)
  │    → Clean up worktree: git worktree remove <agent-root>/issues/issue-<N>
  │
  └─ everything else → drop
```

### Dispatcher Flow

```text
Schedule Trigger (every 60s)
  │
  For each agent (hub-manager, app-manager):
  │
  ├─ List /data/queue/<agent>/ → sort alphabetically (FIFO by timestamp)
  ├─ No files? → skip
  ├─ Read oldest file → extract message + metadata
  ├─ git fetch origin (in <agent-root>/repo/ — always, before every dispatch)
  ├─ If needs_worktree:
  │    ├─ Ensure worktree exists at <agent-root>/issues/issue-<N>/
  │    └─ Prepend "cd <agent-root>/issues/issue-<N>" to message
  │  Else (spec/notification):
  │    └─ Prepend "cd <agent-root>/repo" to message (if not already there)
  ├─ POST /api/agents/{id}/wake (ensure agent is running)
  ├─ PATCH /api/agents/{id}/session (requireIdle: true)
  │    ├─ 409 (busy) → stop, try next cycle
  │    └─ 200 (idle) → command sent, delete job file from queue
  └─ Next agent
```

### Worktree Management

Every issue that needs code work gets its own git worktree. No branch switching, no dirty state — the agent `cd`s into the worktree and works in complete isolation.

#### Directory Layout

Everything for an agent lives under its root directory:

```text
/data/agents/boswell-app-manager/          ← agent root
  repo/                                     ← regular clone on main (spec work + worktree source)
    .claude/                                ← commands/skills available here
    src/
  issues/                                   ← worktrees live here
    issue-5/                                ← worktree: issue/5/work branch
    issue-8/                                ← worktree: issue/8/work branch

/data/agents/boswell-hub-manager/          ← agent root
  repo/                                     ← regular clone on main
  issues/
    issue-12/                               ← worktree
```

AI Maestro `workingDirectory` for each agent points to `repo/` (e.g., `/data/agents/boswell-app-manager/repo`). Claude Code starts there, has full project context and `.claude/` commands. For code tasks, the dispatcher message includes a `cd` to the appropriate worktree.

**Ownership:**

| Concern               | Owner                        | Notes                                                     |
| --------------------- | ---------------------------- | --------------------------------------------------------- |
| Creating worktrees    | Dispatcher (Execute Command) | `git worktree add` before dispatching code tasks          |
| Working in worktrees  | Agent (Claude Code)          | Message includes `cd` path; agent works there             |
| Cleaning up worktrees | Intake workflow              | On `pull_request.closed` + merged → `git worktree remove` |

AI Maestro has no worktree or cwd support — `workingDirectory` is fixed at registration, `PATCH /session` has no `cwd` parameter. Worktree lifecycle is entirely managed by n8n scripts.

#### Which events need a worktree

| Event                          | Worktree?    | Where agent works                                                             |
| ------------------------------ | ------------ | ----------------------------------------------------------------------------- |
| `agent-spec`                   | No           | `repo/` — spec edits GitHub issue body via API, no local code changes         |
| `agent-implement`              | Yes (create) | `issues/issue-N/` — implementation creates branch, writes code, opens PR      |
| `@agent` on issue comment      | If exists    | `issues/issue-N/` if worktree exists, else `repo/`                            |
| `@agent` on PR comment         | Yes (reuse)  | `issues/issue-N/` — feedback targets the PR's branch, worktree already exists |
| `pull_request.opened`          | No           | `repo/` — notification only                                                   |
| `pull_request.closed` + merged | Cleanup      | N/A — remove the worktree                                                     |

#### Worktree Lifecycle

1. `agent-implement` on issue #5 → dispatcher creates worktree:
   ```bash
   AGENT_ROOT="/data/agents/boswell-app-manager"
   git -C "$AGENT_ROOT/repo" fetch origin
   git -C "$AGENT_ROOT/repo" worktree add "$AGENT_ROOT/issues/issue-5" -b issue/5/work origin/main
   chown -R agent:agent "$AGENT_ROOT/issues/issue-5"
   ```
2. Agent receives `cd /data/agents/boswell-app-manager/issues/issue-5 && /dev-start #5`
3. `/dev-start` detects `issue/5/work` branch (not main → branch-protection skill skips creation), works, opens PR
4. `@agent` comment on PR → dispatcher finds existing worktree at `issues/issue-N/`, sends agent there
5. PR merged → intake workflow runs `git -C "$AGENT_ROOT/repo" worktree remove "$AGENT_ROOT/issues/issue-5" --force`

**PR → worktree mapping:** PR head branch follows `issue/{N}/work`. Dispatcher extracts N to find worktree at `issues/issue-{N}/`.

#### Freshness Protocol

Network fetch is required before every dispatch — you or teammates may have pushed changes.

```bash
# ALWAYS run before any dispatch (safe — updates refs only, never touches working trees)
git -C "$AGENT_ROOT/repo" fetch origin
```

| Scenario                      | Freshness action                                                      |
| ----------------------------- | --------------------------------------------------------------------- |
| New worktree                  | `git fetch` + `worktree add ... origin/main` — guaranteed latest main |
| Existing worktree (returning) | **No rebase, no merge.** Agent continues on its branch as-is.         |
| Spec work (in `repo/`)        | `git -C repo pull origin main` — keep main up to date                 |

#### Conflict Strategy

An autonomous system must never silently resolve merge conflicts.

- **New worktrees** are created from `origin/main` after a fresh fetch — zero conflict risk by construction.
- **Existing worktrees** are never rebased onto main. The agent continues on its feature branch. If main has diverged, conflicts surface at PR merge time where a human is already reviewing.
- **Explicit resolution only:** If the human sees conflicts on the PR, they can comment `@agent resolve the merge conflicts with main` — the agent resolves as a deliberate instruction, not an automatic side effect.
- **Crash recovery:** Worktrees persist on disk. If the agent crashes mid-work, uncommitted changes survive locally. Next dispatch to the same issue picks up where the agent left off.

### Filesystem Queue

```text
/data/queue/
  boswell-hub-manager/
    1707900000000-issue-5-implement.json
    1707900060000-issue-8-implement.json
    1707900120000-issue-5-comment.json
  boswell-app-manager/
    1707900030000-issue-3-implement.json
```

Each job file contains the pre-built message and worktree metadata:

```json
{
  "message": "/dev-start #5",
  "issue_number": 5,
  "event_type": "issues.labeled",
  "action": "implement",
  "repo": "teamboswell/boswell-app",
  "needs_worktree": true,
  "queued_at": "2026-02-14T12:00:00Z"
}
```

Timestamp prefix guarantees FIFO. Intake creates files, dispatcher deletes them after successful send.

### AI Maestro API Usage

| Endpoint                         | Used by    | Purpose                                              |
| -------------------------------- | ---------- | ---------------------------------------------------- |
| `POST /api/agents/{id}/wake`     | Dispatcher | Ensure agent is running before sending work          |
| `PATCH /api/agents/{id}/session` | Dispatcher | Send command (with idle check, 409 if busy)          |
| `POST /api/agents/{id}/chat`     | **Never**  | Unsafe — no idle check, can corrupt in-progress work |

Critical: always use PATCH `/session` (not POST `/chat`) for automated dispatch. POST `/chat` blindly types keystrokes into tmux with zero concurrency protection.

---

## Phase A: Cleanup

Remove junk workflows built on incorrect assumptions before AI Maestro API was understood.

### A.1 Delete local junk workflow files

- [x] Delete `workflows/github-auto-implementation.json` (calls nonexistent `ai-maestro-trigger.sh`)
- [x] Delete `workflows/daily-digest.json` (uses community node directly, not AI Maestro API)

### A.2 Remove from n8n server

- [x] SSH in, list workflows, delete the two junk workflows from n8n's database (deleted via python3 + sqlite3 — n8n CLI has no delete command, REST API requires paid tier)
- [x] Verify removal: `n8n list:workflow` shows neither Daily Digest nor GitHub Auto-Implementation

### A.3 Update workflows/README.md

- [x] Remove references to deleted workflows
- [x] Document `faq-seeder.json` as the only current workflow
- [x] Added note: n8n free tier has no REST API, use CLI or SQLite

### A.4 Verify clean state

- [x] `ls workflows/` shows only `faq-seeder.json` and `README.md`
- [x] `n8n list:workflow` confirms no junk workflows remain (18 duplicate FAQ Seeder iterations remain on server from development — cosmetic, not blocking)

---

## Phase B: Intake Workflows + Filesystem Queue

Build the intake workflows that receive GitHub events, validate the gate, and write job files to the queue. No AI Maestro involvement — just prove events arrive, route correctly, and queue reliably.

### B.1 Prerequisites

These must be done first — everything else depends on them.

- [x] Create `agent` label on both repos (legacy gate label — replaced by compound `agent-*` labels in B.2.5b):
  - `gh label create agent --repo teamboswell/boswell-hub --description "Ready for AI agent"`
  - `gh label create agent --repo teamboswell/boswell-app --description "Ready for AI agent"`
- [x] Create queue directories on server (owned by `agent` user so n8n's Execute Command can write):
  - `fly ssh console -a backoffice-automation -C "mkdir -p /data/queue/boswell-hub-manager /data/queue/boswell-app-manager && chown -R agent:agent /data/queue"`
- [x] In n8n UI, create a GitHub credential using the existing `GH_TOKEN` (needs `repo` + `admin:repo_hook` scopes)
- [x] Test the credential connects successfully

### B.2 GitHub Trigger — prove webhooks arrive

Start with just the trigger node to confirm events reach n8n.

- [x] Create new workflow `GitHub Intake (hub)` in n8n UI
- [x] Add **GitHub Trigger node**:
  - Credential: GitHub credential from B.1
  - Owner: `teamboswell`
  - Repository: `boswell-hub`
  - Events: `issues`, `issue_comment`, `pull_request`
- [x] Activate the workflow
- [x] Verify webhook registered: `gh api repos/teamboswell/boswell-hub/hooks`
- [x] Open a test issue on `boswell-hub` → confirm n8n shows an execution in its log

### B.2.5 Agent Environment Setup

Agent working directories, repos, labels, and plugin must be in place before the pipeline can dispatch work.

#### B.2.5a Clone repos into agent working directories

Repos live in `repo/` subdirectory under each agent root. AI Maestro `workingDirectory` points to `repo/`.

- [x] ~~Clone repos into agent root directories (legacy — before worktree layout)~~
- [x] Migrate existing clones from agent root to `repo/` subdirectory:
  - Handled automatically by `migrate_repo_to_subdir()` in entrypoint.sh — verified on deploy
- [x] Update AI Maestro registry.json — change `workingDirectory` to include `/repo`:
  - Handled automatically by `fix_agent_registry()` in entrypoint.sh — verified: all agents show `/repo` path
- [x] Update `entrypoint.sh` `clone_repo_if_missing` to target `repo/` path
- [x] Deploy and verify: repos at `<agent-root>/repo/`, owned by `agent`, AI Maestro workDir updated, agent wakes successfully

#### B.2.5b Create compound labels

- [x] Create `agent-spec` label on both repos:
  - `gh label create agent-spec --repo teamboswell/boswell-hub --description "Agent writes spec"`
  - `gh label create agent-spec --repo teamboswell/boswell-app --description "Agent writes spec"`
- [x] Create `agent-implement` label on both repos:
  - `gh label create agent-implement --repo teamboswell/boswell-hub --description "Agent implements"`
  - `gh label create agent-implement --repo teamboswell/boswell-app --description "Agent implements"`

#### B.2.5c Install ralph-wiggum plugin

Ralph-wiggum is a Claude Code plugin (from `anthropics/claude-code` demo marketplace, registers as `claude-code-plugins`) that creates an autonomous loop — Claude works, tries to exit, stop hook re-feeds the prompt, loop repeats until a completion promise is met or max iterations reached. This prevents agents from quitting early on complex tasks.

- [x] Add marketplace: `claude plugin marketplace add anthropics/claude-code` (as `agent` user)
- [x] Install plugin: `claude plugin install ralph-wiggum@claude-code-plugins --scope user`
- [x] Add conditional install to `entrypoint.sh` — skip if already present on persistent volume
- [x] Verify: plugin installed in cache at `/data/claude/plugins/cache/claude-code-plugins/ralph-wiggum`, agent wakes successfully

#### B.2.5d Create worktree issues directories

- [x] Create directories on server — verified: `issues/` exists in both agent roots
- [x] Add to `entrypoint.sh` `setup_agent_working_directories()` — creates `issues/` dirs on every boot

### Webhook → Agent Routing Reference

This table defines the complete routing logic. The IF gate and Switch node (B.3) filter events; the Code node (B.4) builds the message.

#### Gate Logic

| GitHub Event            | Gate Check                                                  | Result                                             |
| ----------------------- | ----------------------------------------------------------- | -------------------------------------------------- |
| `issues.labeled`        | `label.name` starts with `agent-`?                          | Yes → route by label suffix                        |
| `issues.labeled`        | `label.name` does NOT start with `agent-`?                  | Drop                                               |
| `issue_comment.created` | Comment body contains `@agent`? AND `sender.type != "Bot"`? | Yes → extract instruction, route to comment branch |
| `issue_comment.created` | No `@agent` mention, OR sender is bot?                      | Drop                                               |
| `pull_request.opened`   | Always                                                      | Pass through → PR notification branch              |
| `pull_request.closed`   | `merged == true`?                                           | Yes → worktree cleanup branch (no queue)           |
| `pull_request.closed`   | `merged == false`?                                          | Drop (or future: cleanup closed-without-merge)     |
| Any other event         | —                                                           | Drop                                               |

#### Message Routing (per event × per repo)

| Event            | Label/Trigger          | Message (dispatcher prepends `cd` to correct directory)                                                                                                          | Worktree?             |
| ---------------- | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- |
| Issue labeled    | `agent-spec`           | `cd <root>/repo && /github:update-issue #N` (app) / `cd <root>/repo && Read issue #N...` (hub)                                                                   | No — works in `repo/` |
| Issue labeled    | `agent-implement`      | `cd <root>/issues/issue-N && /ralph-wiggum:ralph-loop "/dev-start #N" ...`                                                                                       | Yes (create)          |
| Comment on issue | `@agent <instruction>` | `cd <root>/issues/issue-N && <instruction>` (if worktree exists, else `cd <root>/repo && <instruction>`)                                                         | If exists             |
| Comment on PR    | `@agent <instruction>` | `cd <root>/issues/issue-N && <instruction>` — instruction is passed through verbatim (may be a slash command like `/dev-apply-feedback ...` or natural language) | Yes (reuse)           |
| PR opened        | (no gate)              | `cd <root>/repo && New PR #N: "<title>". Review at <url>.`                                                                                                       | No — works in `repo/` |
| PR merged        | (no gate)              | — (no agent message — worktree cleanup only)                                                                                                                     | Cleanup               |

#### Why these commands?

| Command                     | Repo        | What it does                                                                                                                                                                                                        |
| --------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/github:update-issue #N`   | boswell-app | Fetches issue, invokes `spec-writing` skill, updates issue body with generated spec. Single step, output goes to GitHub.                                                                                            |
| `/dev-start #N`             | boswell-app | Phase-based orchestrator: auto-detects intent from issue number, analyst creates work state, phase-implementor executes TDD per phase, creates PR. Full pipeline with branch protection, work state, and subagents. |
| `/dev-apply-feedback <url>` | boswell-app | Validates PR review feedback via analyst, creates new phases for actionable items, resumes dev-start to execute them.                                                                                               |
| `/implement "inline text"`  | boswell-hub | Basic TDD: Red-Green-Refactor cycle. Receives issue title + body as inline text since the command doesn't accept URLs. Simpler than boswell-app's pipeline.                                                         |
| Natural language (spec)     | boswell-hub | No spec command exists — agent receives a natural language prompt to write a spec.                                                                                                                                  |
| Natural language (feedback) | boswell-hub | No feedback command exists — agent receives the feedback and decides how to act.                                                                                                                                    |

#### Ralph-wiggum wrapping

Only `agent-implement` is wrapped in `/ralph-wiggum:ralph-loop`. This ensures the agent persists through ambiguity until it outputs `COMPLETE` or hits 30 iterations. Spec, comment, and PR events are single-pass — the agent does one thing and stops.

---

### B.3 Build hub intake nodes ✅

Built `github-intake-hub-v2.json`: GitHub Trigger → Code "Process Event" → Execute Command "Handle Event". Published and webhook active on boswell-hub (webhook ID 596593007).

**Bugs found and fixed during implementation:**

- n8n GitHub Trigger event values must use snake_case (`issue_comment`, `pull_request`), not camelCase
- GitHub Trigger wraps payload in `$json.body` — Code node must use `const event = $json.body || $json`
- Regex `\b@agent\b` never matches because `@` is non-word character — fixed to `/@agent\b/i`
- n8n runs published version from `workflow_history` table, not `workflow_entity.nodes` — DB edits must update both

### B.4 Build dispatcher workflow ✅

Built `agent-dispatcher.json`: Schedule Trigger (60s) → Execute Command "Dispatch Work". Single bash script handles queue reading, git fetch, worktree setup, AI Maestro wake + dispatch, job file cleanup.

### B.5 End-to-end test ✅

Verified via smoke tests on both repos:

- `agent-spec` label → queue file with correct message and `needs_worktree: false`
- `@agent` comment → queue file with extracted instruction and `needs_worktree: "if_exists"`
- Dispatcher consumed all queue files within 60s cycles, agents received commands

### B.6 Duplicate intake for boswell-app ✅

Built `github-intake-app-v2.json`: same architecture, targeting `boswell-app` → `boswell-app-manager`. Published and webhook active on boswell-app (webhook ID 596597659). Full pipeline verified — all 3 nodes green in execution view.

### B.7 Export workflows + cleanup ✅

Exported all production workflows from server, stripped runtime data (IDs, staticData), saved to `workflows/`. Updated `workflows/CLAUDE.md` with all workflow documentation. Removed old v1 hub intake file.

---

## Phase C: GitHub Status Comments

Post progress comments on GitHub issues/PRs so humans see that the system acknowledged their request and know when work completes. The dispatcher owns the full comment lifecycle — the agent is never responsible for status updates.

### Design

**Single comment per dispatched job**, edited over time:

```markdown
🤖 **boswell-hub-manager** is working on this issue.

**Task:** implement · **Issue:** #42
**Started:** 2026-02-17 12:31 UTC
**Status:** ⏳ In progress...
```

Updated on completion to:

```markdown
🤖 **boswell-hub-manager** finished working on this issue.

**Task:** implement · **Issue:** #42
**Started:** 2026-02-17 12:31 UTC
**Completed:** 2026-02-17 12:35 UTC · Duration: 4m
**Status:** ✅ Complete
```

### Why the dispatcher, not the intake or the agent

- **Not intake**: Intake fires instantly but doesn't know when the agent actually starts (could be queued for minutes if agent is busy). A "received" comment before the agent starts is noise.
- **Not the agent**: User explicitly wants the agent unburdened. The agent's job is to do the work, not report on itself. Also, agent crashes would leave stale "in progress" comments with no recovery path.
- **Dispatcher**: Knows the exact moment work is dispatched. Polls every 60s so it can detect completion within ~60s. Already has all the context (issue number, repo, action type).

### State tracking

When the dispatcher successfully dispatches a job, it writes a state file:

```text
/data/queue/<agent>/.active
```

```json
{
  "comment_id": 12345,
  "issue_number": 42,
  "repo": "teamboswell/boswell-hub",
  "action": "implement",
  "started_at": "2026-02-17T12:31:00Z"
}
```

Only one `.active` file per agent at a time (agents process one job at a time).

### Idle detection

AI Maestro `GET /api/agents/{id}` returns `session.status` ("online"/"offline") but not busy/idle. Need to determine idle state without sending a command.

**Options (to be tested in C.1):**

1. **`PATCH /session` with `requireIdle: true` + dummy command** — if 200, agent was idle (but we just sent a no-op). If 409, busy. Drawback: sends unwanted input.
2. **tmux prompt detection** — `tmux capture-pane -p -t <agent> | tail -5` and grep for Claude Code's idle prompt (`>`). Reliable if the prompt pattern is stable.
3. **`session.lastActivity` delta** — if `lastActivity` hasn't changed in >30s, likely idle. Fragile — activity timestamps may not update in real time.

Recommended: start with option 2 (tmux capture). It's read-only, zero side effects, and Claude Code's prompt is distinctive.

### Implementation steps

#### C.1 Research: verify idle detection method ✅

Tested on server — AI Maestro and tmux not running (clean idle baseline). Approach: `tmux capture-pane -p -t $AGENT_NAME` — no session = agent not running = idle. When session exists, check last non-empty line for Claude Code's idle prompt (`❯` or `>`). Busy state shows output/thinking text instead.

#### C.2 Verify `gh` CLI / GitHub API auth on server ✅

`gh` CLI at `/usr/bin/gh`, `GH_TOKEN` env var set, authenticated rate limit 4993/5000. Read/write access to both repos confirmed via curl. Will use `urllib.request` in python3 heredocs (avoids bash JSON escaping).

#### C.3 Modify dispatcher script ✅

Added two new sections to the dispatcher bash script:

**Section 1 — Completion check (runs BEFORE processing new jobs):**

```text
For each agent:
  If .active file exists:
    Check if agent is idle (tmux capture or API)
    If idle:
      Calculate duration
      Build completion comment body
      PATCH the GitHub comment (using saved comment_id)
      Delete .active file
    If busy and started_at > 2 hours ago:
      Update comment to "⚠️ Agent may be stuck (>2h)"
```

**Section 2 — Start comment (runs AFTER successful dispatch):**

```text
After PATCH /session returns 200:
  Build start comment body
  POST GitHub comment via gh api / curl
  Save comment_id + metadata to .active file
```

- [x] Write updated dispatcher script with both sections — completion check uses tmux capture-pane + python3 heredocs for GitHub API; start comment posted after successful dispatch
- [x] Include the job `repo` field in the queue file (already present) to target the correct GitHub repo for the comment

#### C.4 Deploy and test ✅

- [x] Update dispatcher in DB (both `workflow_entity` and `workflow_history`) — via python3 script uploaded to server
- [x] Restart n8n — `fly apps restart backoffice-automation`
- [x] Test start comment: created test issue #1104, added `agent-spec` label → start comment posted at 14:02 UTC
- [x] Test completion update: next cycle (14:03 UTC) detected idle → updated comment to "finished" with duration
- [ ] Test busy skip: deferred — needs agent actively running a long task
- [ ] Test timeout: deferred — needs >2h active state

#### C.5 Export updated dispatcher ✅

- [x] Local `workflows/agent-dispatcher.json` already updated via build script — verified matches server (7890 chars)

---

## Phase D: Email-to-Bug-Report (future)

Gmail trigger → classify email → if customer bug report → wake agent → create GitHub issue.

- [ ] Gmail Trigger node (poll for new emails from customers)
- [ ] Code/AI node to classify: is this a bug report, feature request, or noise?
- [ ] If bug report: HTTP Request to wake agent → chat with bug details → agent creates GitHub issue
- [ ] If feature request: log for manual review (or create issue with `enhancement` label)

---

## Phase E: Daily Digest (future)

Schedule trigger → query GitHub for open issues/PRs → summarize → notify.

- [ ] Schedule Trigger (daily, e.g., 9am ET)
- [ ] GitHub node: fetch open issues and PRs for both repos
- [ ] Wake agent → chat "Summarize today's open issues and PRs" → get response
- [ ] Send summary (email, Slack, or write to file)
