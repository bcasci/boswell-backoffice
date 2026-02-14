---
name: create-maestro-agent
description: Create a new AI Maestro agent on the backoffice-automation Fly.io server with proper directory ownership, API registration, tags, and wake/hibernate verification.
argument-hint: "[agent-name] for [repo-or-purpose]"
disable-model-invocation: true
allowed-tools: Bash
---

Create a new AI Maestro agent. Parse the agent name and purpose from: $ARGUMENTS

## Steps

### 1. Create working directory (owned by agent user)

CRITICAL: `fly ssh console` runs as root. The `agent` user runs Claude Code. Without `chown`, the agent can't write files.

```bash
fly ssh console -a backoffice-automation -C "mkdir -p /data/agents/$0 && chown -R agent:agent /data/agents/$0"
```

### 2. Register agent via AI Maestro API

```bash
fly ssh console -a backoffice-automation -C "curl -s -X POST http://localhost:23001/api/agents -H 'Content-Type: application/json' -d '{\"name\":\"$0\",\"workingDirectory\":\"/data/agents/$0\",\"program\":\"claude-code\",\"programArgs\":\"--dangerously-skip-permissions\",\"taskDescription\":\"Agent for $1\"}'"
```

Save the returned `id` from the JSON response.

### 3. Add tags for dashboard grouping

API PUT does NOT reliably update tags. Edit the registry file directly. Derive the group tag from the agent name (e.g., `boswell-hub-manager` → `hub`, `boswell-app-manager` → `app`).

```bash
fly ssh console -a backoffice-automation -C "python3 -c \"
import json
with open('/data/ai-maestro/agents/registry.json') as f:
    agents = json.load(f)
for a in agents:
    if a.get('name') == '<agent-name>':
        a['tags'] = ['boswell', '<group-tag>']
with open('/data/ai-maestro/agents/registry.json', 'w') as f:
    json.dump(agents, f, indent=2)
\""
```

### 4. Wake the agent to verify

```bash
fly ssh console -a backoffice-automation -C "curl -s -X POST http://localhost:23001/api/agents/<agent-id>/wake"
```

Confirm `"programStarted": true` in the response.

### 5. Hibernate the agent

```bash
fly ssh console -a backoffice-automation -C "curl -s -X POST http://localhost:23001/api/agents/<agent-id>/hibernate"
```

### 6. Report results

Tell the user: agent name, ID, working directory, tags, and wake/hibernate test result.
