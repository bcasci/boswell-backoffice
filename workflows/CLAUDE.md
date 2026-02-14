# n8n Workflows

Workflow JSON files baked into the Docker image at `/opt/workflows/` and imported into n8n on first boot. Flag file `/data/n8n/.workflows-seeded` prevents re-import on subsequent deploys.

## Current Workflows

### faq-seeder.json

Gmail → ConvertToFile → WriteToDisk → Execute Command (Claude). Fetches customer emails, processes in batches of 15, extracts FAQ entries to `/data/customer-faq.md`.

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
