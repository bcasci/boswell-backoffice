# n8n ↔ GitHub ↔ AI Maestro Integration Plan

**Objective:** Connect GitHub events to AI Maestro agents via n8n so that issues, comments, and PRs automatically trigger Claude Code to analyze, respond, and implement.

**Date:** 2026-02-13
**Status:** Phase A Complete — Phase B ready to implement
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

### Gate

`agent` label on issues. No label = ignored. PRs ungated (reviews are read-only).

Guards:

- `issue_comment`: skip if issue lacks `agent` label, or `sender.type == "Bot"`
- `issues.labeled`: only act when `label.name == "agent"`

### Intake Flow

```text
GitHub Trigger (issues, issue_comment, pull_request)
  │
  ├─ issues.labeled (label.name == "agent")
  │    → Write job file to /data/queue/<agent>/
  │
  ├─ issue_comment.created (issue has "agent" label + sender not bot)
  │    → Write job file to /data/queue/<agent>/
  │
  ├─ pull_request.opened (no label gate)
  │    → Write job file to /data/queue/<agent>/
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
  ├─ Read oldest file → extract message
  ├─ POST /api/agents/{id}/wake (ensure agent is running)
  ├─ PATCH /api/agents/{id}/session (requireIdle: true)
  │    ├─ 409 (busy) → stop, try next cycle
  │    └─ 200 (idle) → command sent, delete job file from queue
  └─ Next agent
```

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

Each job file contains the pre-built message for the agent:

```json
{
  "message": "Issue #5 labeled agent. Read https://github.com/..., implement the fix, and create a PR.",
  "issue_number": 5,
  "event_type": "issues.labeled",
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

- [ ] Create `agent` label on both repos:
  - `gh label create agent --repo teamboswell/boswell-hub --description "Ready for AI agent"`
  - `gh label create agent --repo teamboswell/boswell-app --description "Ready for AI agent"`
- [ ] Create queue directories on server (owned by `agent` user so n8n's Execute Command can write):
  - `fly ssh console -a backoffice-automation -C "mkdir -p /data/queue/boswell-hub-manager /data/queue/boswell-app-manager && chown -R agent:agent /data/queue"`
- [ ] In n8n UI, create a GitHub credential using the existing `GH_TOKEN` (needs `repo` + `admin:repo_hook` scopes)
- [ ] Test the credential connects successfully

### B.2 GitHub Trigger — prove webhooks arrive

Start with just the trigger node to confirm events reach n8n.

- [ ] Create new workflow `GitHub Intake (hub)` in n8n UI
- [ ] Add **GitHub Trigger node**:
  - Credential: GitHub credential from B.1
  - Owner: `teamboswell`
  - Repository: `boswell-hub`
  - Events: `issues`, `issue_comment`, `pull_request`
- [ ] Activate the workflow
- [ ] Verify webhook registered: `gh api repos/teamboswell/boswell-hub/hooks`
- [ ] Open a test issue on `boswell-hub` → confirm n8n shows an execution in its log

### B.3 Switch node — prove routing works

Add the gate and routing logic.

- [ ] Add **Switch node** after the GitHub Trigger:
  - Branch 1: `issues.labeled` where `label.name == "agent"`
  - Branch 2: `issue_comment.created` where issue has `agent` label AND `sender.type != "Bot"`
  - Branch 3: `pull_request.opened` (no label gate)
  - Default: no-op (drop)
- [ ] Test: add `agent` label to the test issue → confirm Branch 1 fires
- [ ] Test: comment on the issue → confirm Branch 2 fires
- [ ] Test: remove `agent` label, comment again → confirm it hits default (gate works)

### B.4 Code + Write File — prove queue works

Add the job file builder and writer to each branch.

**Code node** (same on each branch, builds the job file content):

```javascript
const now = Date.now();
const issueNum = $json.issue?.number || $json.pull_request?.number;
const action = $json.action;

let message;
if ($json.pull_request) {
  message = `New PR #${$json.pull_request.number}: ${$json.pull_request.title}. Review the changes at ${$json.pull_request.html_url}.`;
} else if (action === "labeled") {
  message = `Issue #${$json.issue.number} labeled agent. Read ${$json.issue.html_url}, implement the fix, and create a PR.`;
} else if (action === "created") {
  message = `New comment on issue #${$json.issue.number} from ${$json.comment.user.login}: ${$json.comment.body}. Read the full thread and respond or take action.`;
}

return [
  {
    json: {
      fileName: `${now}-issue-${issueNum}-${action}.json`,
      content: JSON.stringify(
        {
          message,
          issue_number: issueNum,
          event_type: `${$json.pull_request ? "pull_request" : "issues"}.${action}`,
          queued_at: new Date().toISOString(),
        },
        null,
        2,
      ),
    },
  },
];
```

**Write File node** (after each Code node):

- Path: `/data/queue/boswell-hub-manager/{{ $json.fileName }}`
- Content: `{{ $json.content }}`

- [ ] Add Code node + Write File node to each Switch branch
- [ ] Test: add `agent` label to a new issue → confirm job file appears in `/data/queue/boswell-hub-manager/`
- [ ] Test: comment on labeled issue → confirm second job file appears
- [ ] Inspect files: `fly ssh console -a backoffice-automation -C "ls -la /data/queue/boswell-hub-manager/"` — verify FIFO order by timestamp prefix
- [ ] Read a job file: `fly ssh console -a backoffice-automation -C "cat /data/queue/boswell-hub-manager/<filename>"` — verify message content is correct

### B.5 Duplicate for boswell-app

- [ ] Clone the hub intake workflow in n8n UI
- [ ] Change GitHub Trigger to owner `teamboswell`, repo `boswell-app`
- [ ] Change Write File path to `/data/queue/boswell-app-manager/`
- [ ] Activate and verify webhook registered: `gh api repos/teamboswell/boswell-app/hooks`

### B.6 Export intake workflow JSONs

- [ ] Export both intake workflows from n8n UI
- [ ] Save to `workflows/github-intake-hub.json` and `workflows/github-intake-app.json`

### B.7 Clean up test data

- [ ] Delete test queue files: `fly ssh console -a backoffice-automation -C "rm -f /data/queue/boswell-hub-manager/*"`
- [ ] Close test issues on GitHub

---

**PAUSE.** Phase B is complete when webhooks arrive, the Switch routes correctly, and job files appear in the queue in FIFO order. Review results, discuss, then proceed to Phase C.

---

## Phase C: Agent Dispatcher

**Depends on:** Phase B complete and verified.

Build the dispatcher workflow that polls the queue and sends work to agents when they're idle.

### C.1 Get agent IDs

- [ ] `fly ssh console -a backoffice-automation -C "curl -s http://localhost:23001/api/agents"` — note the `id` for `boswell-hub-manager` and `boswell-app-manager`

### C.2 Build the dispatcher workflow

Create `Agent Dispatcher` workflow in n8n UI:

1. **Schedule Trigger node** — every 60 seconds

2. **Code node** — define agent config:

   ```javascript
   return [
     {
       json: {
         agentName: "boswell-hub-manager",
         agentId: "<hub-agent-id>",
         queueDir: "/data/queue/boswell-hub-manager",
       },
     },
     {
       json: {
         agentName: "boswell-app-manager",
         agentId: "<app-agent-id>",
         queueDir: "/data/queue/boswell-app-manager",
       },
     },
   ];
   ```

3. **For each agent** (n8n processes items sequentially):

   a. **Execute Command node** — list queue files:
   - Command: `ls -1 {{ $json.queueDir }}/ 2>/dev/null | head -1`
   - If empty output → no work → skip (IF node)

   b. **Execute Command node** — read oldest job file:
   - Command: `cat {{ $json.queueDir }}/{{ $json.oldestFile }}`
   - Parse JSON to get the message

   c. **HTTP Request node** — wake agent:
   - `POST http://localhost:23001/api/agents/{{ $json.agentId }}/wake`

   d. **HTTP Request node** — dispatch (with idle check):
   - `PATCH http://localhost:23001/api/agents/{{ $json.agentId }}/session`
   - Body: `{ "command": "{{ $json.message }}", "requireIdle": true }`
   - On 409 → stop (IF node checks response code), try next cycle
   - On 200 → continue to cleanup

   e. **Execute Command node** — remove job file from queue:
   - Command: `rm {{ $json.queueDir }}/{{ $json.oldestFile }}`

- [ ] Build workflow in n8n UI
- [ ] Activate the workflow

### C.3 End-to-end verification

- [ ] Label an issue `agent` on `boswell-hub` → verify job file created (Phase B)
- [ ] Wait up to 60s → dispatcher picks up job → agent wakes → Claude implements → creates PR
- [ ] Label a second issue while agent is busy → verify job file queues
- [ ] Agent finishes first issue → dispatcher picks up second issue on next cycle
- [ ] Test comment on labeled issue → queues and dispatches correctly
- [ ] Test PR opened → queues and dispatches correctly

### C.4 Queue monitoring

- [ ] Verify queue drains: `fly ssh console -a backoffice-automation -C "ls /data/queue/boswell-hub-manager/"`
- [ ] Verify no orphaned files after agent completes work

### C.5 Export dispatcher workflow

- [ ] Export workflow from n8n UI as JSON
- [ ] Save to `workflows/agent-dispatcher.json`

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
