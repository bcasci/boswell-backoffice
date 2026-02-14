---
name: deploy-n8n-workflow
description: Deploy or update an n8n workflow JSON on the backoffice-automation Fly.io server. Handles both first-time and update scenarios.
argument-hint: "[workflow-file.json]"
disable-model-invocation: true
allowed-tools: Bash
---

Deploy an n8n workflow to the server. Parse the workflow filename from: $ARGUMENTS

## Context

- Workflow JSONs live in `workflows/` locally and are baked into the image at `/opt/workflows/`
- On first boot, `entrypoint.sh` imports all workflows from `/opt/workflows/` into n8n's SQLite DB
- A flag file `/data/n8n/.workflows-seeded` prevents re-import on subsequent boots
- n8n caches workflows in memory — CLI import alone doesn't update the running server

## Option A: First-time deployment (new workflow, not yet on server)

1. Ensure the workflow JSON exists in `workflows/`:

```bash
ls workflows/$ARGUMENTS
```

2. Deploy the image (workflow gets baked in and imported on next clean boot):

```bash
fly deploy
```

If the seed flag already exists, either:

- Delete it and restart: `fly ssh console -a backoffice-automation -C "rm /data/n8n/.workflows-seeded" && fly apps restart backoffice-automation`
- Or import directly (Option B)

## Option B: Update existing workflow or push without full redeploy

1. Copy the workflow JSON to the server:

```bash
fly ssh console -a backoffice-automation -C "cat > /tmp/workflow.json" < workflows/$ARGUMENTS
```

2. Import into n8n's database:

```bash
fly ssh console -a backoffice-automation -C "N8N_USER_FOLDER=/data/n8n n8n import:workflow --input=/tmp/workflow.json"
```

3. Restart n8n to pick up changes (CLI import writes to SQLite but doesn't update the running server's memory cache):

```bash
fly ssh console -a backoffice-automation -C "pkill -f 'n8n start' && sleep 2 && echo 'n8n will auto-restart via entrypoint.sh'"
```

4. Clean up:

```bash
fly ssh console -a backoffice-automation -C "rm /tmp/workflow.json"
```

## Verification

After deployment, confirm the workflow appears in the n8n UI at https://backoffice-automation.fly.dev/

## Gotchas

- **n8n file access restricted**: WriteBinaryFile/ReadWriteFile can only access paths in `N8N_RESTRICT_FILE_ACCESS_TO` (set to `/tmp;/data` in fly.toml). Semicolon-separated.
- **n8n expression syntax**: Use `$input.all().map(i => i.json)` NOT `$items`. Code node sandbox blocks `require('fs')` and `require('child_process')`.
- **Workflow IDs**: If importing over an existing workflow, the JSON must have the same `id` field or n8n creates a duplicate.
