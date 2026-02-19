# n8n Workflows

Workflow JSON files baked into the Docker image at `/opt/workflows/` and imported into n8n on first boot. Flag file `/data/n8n/.workflows-seeded` prevents re-import on subsequent deploys.

## Current Workflows

### github-intake-hub-v2.json

GitHub Trigger → Code "Process Event" → Execute Command "Handle Event". Receives webhook events from `teamboswell/boswell-hub`, gates on `agent-*` labels and `@agent` comments, writes job files to `/data/queue/boswell-hub-manager/`. Also handles PR merge → worktree cleanup.

### github-intake-app-v2.json

Same architecture as hub intake, targeting `teamboswell/boswell-app` → `/data/queue/boswell-app-manager/`.

### agent-dispatcher.json

Schedule Trigger (60s) → Execute Command "Dispatch Work". Two phases per cycle:

1. **Completion check**: For each agent with a `.active` file, checks if agent is idle via `tmux capture-pane`. If idle → PATCHes the GitHub comment to "Complete" with duration, deletes `.active`. If busy >2h → warns "may be stuck".
2. **Dispatch**: Polls both agent queues, reads oldest job file (FIFO), does git fetch, creates per-issue clone if needed (local `git clone` from repo/, sets remote to GitHub URL, creates `issue/{N}/work` branch), sets agent's `workingDirectory` via AI Maestro PATCH API, wakes agent, dispatches command (with extra Enter for reliability), deletes job file on success, POSTs a start comment on the GitHub issue, writes `.active` state file. On completion, resets `workingDirectory` to default.

### faq-seeder.json

Gmail → ConvertToFile → WriteToDisk → Execute Command (Claude). Fetches customer emails, processes in batches of 15, extracts FAQ entries to `/data/customer-faq.md`.

## Fresh Deploy / Rebuild

Workflow JSONs are seeded automatically from the Docker image on first boot. Credentials and activation are manual steps.

### Fly Secrets Required

| Secret | Purpose |
|--------|---------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code auth for AI Maestro agents |
| `GH_TOKEN` | GitHub access — needs `repo` + `admin:repo_hook` scopes |
| `GITHUB_OAUTH_CLIENT_ID` | OAuth app for AI Maestro dashboard auth |
| `GITHUB_OAUTH_CLIENT_SECRET` | OAuth app secret |

### n8n Credentials (manual setup after fresh deploy)

These must be created in the n8n UI (`https://backoffice-automation.fly.dev` → Credentials):

1. **GitHub credential** — used by GitHub Trigger nodes for webhook registration
   - Type: GitHub API
   - Token: use the `GH_TOKEN` value from Fly secrets
   - Scopes needed: `repo` + `admin:repo_hook`
   - Referenced by: GitHub Intake (hub), GitHub Intake (app)

2. **Gmail credential** — used by FAQ Seeder workflow
   - Type: Gmail OAuth2
   - Referenced by: FAQ Seeder

### Post-credential steps

After creating credentials, open each workflow in the n8n UI and:
1. Assign the credential to the relevant nodes (GitHub Trigger, Gmail)
2. Activate the workflow
3. Verify webhooks registered: `gh api repos/teamboswell/boswell-hub/hooks` and `gh api repos/teamboswell/boswell-app/hooks`

## n8n Free Tier Constraints

- **No REST API** — use CLI or SQLite directly for server-side workflow management
- **CLI commands**: `n8n list:workflow`, `n8n import:workflow`, `n8n export:workflow` (no delete command)
- **Deleting workflows**: Use python3 + sqlite3 against `/data/n8n/.n8n/database.sqlite` (`DELETE FROM workflow_entity WHERE id=?`)
- **CLI requires**: `N8N_USER_FOLDER=/data/n8n` env prefix, and `bash -c '...'` wrapper when using `fly ssh console -C`

## n8n Expression & Code Gotchas

- Use `$input.all().map(i => i.json)` — NOT `$items` (doesn't exist)
- Code node sandbox blocks `require('fs')` and `require('child_process')`
- `N8N_RESTRICT_FILE_ACCESS_TO=/tmp;/data` in fly.toml — semicolon-separated (colons don't work). Without this, WriteBinaryFile/ReadWriteFile can only write to `~/.n8n-files`
- CLI import writes to SQLite only — running server caches workflows in memory. Restart n8n or use the UI to pick up changes.
- Importing a workflow with the same `id` field overwrites it. Different `id` creates a duplicate.

## GitHub Trigger Node

- Node type: `n8n-nodes-base.githubTrigger` (built-in, no community node needed)
- Auto-registers webhooks on GitHub when workflow is activated
- Handles HMAC-SHA256 signature validation internally
- Auto-deregisters webhook when workflow is deactivated
- Requires GitHub credential with `repo` + `admin:repo_hook` scopes
- **Wraps payload**: output is `{body: {webhook payload}, headers: {...}, query: {...}}`. Code nodes must use `$json.body.action`, NOT `$json.action`
- **Event values**: must use GitHub API snake_case names (`issues`, `issue_comment`, `pull_request`), NOT camelCase

## Editing Workflows via DB

n8n free tier has no API. CLI import (`n8n import:workflow`) only writes to `workflow_entity` and does NOT publish — the running server ignores it until manually published in the UI. **Do not use CLI import for updates.**

Instead, modify the DB directly with python3 + sqlite3. This is the only programmatic way to update a running workflow:

```python
#!/usr/bin/env python3
"""Template: update an n8n workflow node in-place."""
import sqlite3, json

DB = "/data/n8n/.n8n/database.sqlite"
WORKFLOW_NAME = "Agent Dispatcher"  # find by name
NODE_NAME = "Dispatch Work"         # node to modify

conn = sqlite3.connect(DB)
cur = conn.cursor()

# 1. Update workflow_entity
cur.execute("SELECT id, nodes FROM workflow_entity WHERE name = ?", (WORKFLOW_NAME,))
wf_id, nodes_json = cur.fetchone()
nodes = json.loads(nodes_json)
for node in nodes:
    if node.get("name") == NODE_NAME:
        node["parameters"]["command"] = new_script  # or modify jsCode, etc.
        break
cur.execute("UPDATE workflow_entity SET nodes = ? WHERE id = ?",
            (json.dumps(nodes), wf_id))

# 2. Update ALL workflow_history entries (n8n runs the published version from here)
cur.execute("SELECT versionId, nodes FROM workflow_history WHERE workflowId = ?", (wf_id,))
for vid, hist_json in cur.fetchall():
    hist_nodes = json.loads(hist_json)
    for node in hist_nodes:
        if node.get("name") == NODE_NAME:
            node["parameters"]["command"] = new_script
            break
    cur.execute("UPDATE workflow_history SET nodes = ? WHERE versionId = ?",
                (json.dumps(hist_nodes), vid))

conn.commit()
conn.close()
```

**Procedure:**
1. Write the deploy script locally at `/tmp/deploy-*.py`
2. Upload via SFTP: `echo "put /tmp/deploy-foo.py /tmp/deploy-foo.py" | fly ssh sftp shell -a backoffice-automation`
3. Run: `fly ssh console -a backoffice-automation -C "python3 /tmp/deploy-foo.py"`
4. Restart: `fly apps restart backoffice-automation`
5. Webhook registrations survive restarts — no need to re-activate

**For string replacements** (simpler when changing a specific value across the workflow):
```python
cur.execute("SELECT id, nodes FROM workflow_entity WHERE name = ?", (name,))
wf_id, nodes_json = cur.fetchone()
if OLD_TEXT in nodes_json:
    cur.execute("UPDATE workflow_entity SET nodes = ? WHERE id = ?",
                (nodes_json.replace(OLD_TEXT, NEW_TEXT), wf_id))
# ... same for workflow_history ...
```

**Key facts:**
- `workflow_history` uses `versionId` as primary key (NOT `id`)
- `workflow_entity.activeVersionId` points to the published version in `workflow_history`
- Always update BOTH tables — updating only `workflow_entity` has no effect on the running workflow
- sqlite3 CLI is not available on the server — use `python3 -c "import sqlite3; ..."`
