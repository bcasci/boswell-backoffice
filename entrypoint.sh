#!/bin/bash
set -e

# =============================================================================
# Backoffice Automation Entrypoint
# =============================================================================
# Starts n8n, AI Maestro, and Caddy auth proxy.
#
# Services:
#   - n8n          → port 5678  (workflow automation)
#   - AI Maestro   → port 23001 (internal, agent orchestration dashboard)
#   - Caddy        → port 23000 (auth proxy for AI Maestro)
#
# AI Maestro runs as the 'agent' user (not root). This is critical because:
#   - AI Maestro creates tmux sessions that inherit the calling user
#   - Claude Code's --dangerously-skip-permissions is blocked for root
#   - Running as 'agent' means tmux sessions + Claude Code run as non-root
#   - This matches AI Maestro's own agent-container pattern (non-root user)
#
# Persistent volume: /data (survives deploys)
#   /data/n8n          - n8n workflows and settings
#   /data/ai-maestro   - AI Maestro config (agents, hosts, teams)
#   /data/claude       - Claude Code auth and settings
#   /data/agents       - Agent working directories
#   /data/repos        - Cloned repositories
# =============================================================================

MAESTRO_PUBLIC_URL="${MAESTRO_PUBLIC_URL:-https://backoffice-automation.fly.dev:23000}"
SELF_HOST_ID=$(hostname)

# =============================================================================
# Data & Directory Setup
# =============================================================================

setup_data_directories() {
    echo "Setting up data directories..."
    sudo mkdir -p /data/n8n /data/ai-maestro /data/repos /data/worktrees /data/agents \
        /data/queue/boswell-hub-manager /data/queue/boswell-app-manager
    sudo chown -R agent:agent /data

    if [ ! -L /home/agent/.n8n ]; then
        ln -s /data/n8n /home/agent/.n8n
    fi
}

# =============================================================================
# Claude Code Configuration
# =============================================================================

setup_claude_config() {
    # Data directory on persistent volume
    if [ ! -d /data/claude ]; then
        mkdir -p /data/claude
        chown agent:agent /data/claude
    fi

    # Internal settings file inside .claude/ directory
    if [ ! -f /data/claude/.claude.json ]; then
        echo '{"hasCompletedOnboarding":true}' > /data/claude/.claude.json
        chown agent:agent /data/claude/.claude.json
    fi

    # Symlink ~/.claude -> /data/claude for both users
    if [ ! -L /home/agent/.claude ]; then
        ln -s /data/claude /home/agent/.claude
    fi
    rm -rf /root/.claude
    ln -s /data/claude /root/.claude

    # Claude Code reads ~/.claude.json (at HOME root, NOT inside .claude/) for settings.
    # MERGE required fields into existing config rather than overwriting.
    # - hasCompletedOnboarding=true: skip interactive login, use CLAUDE_CODE_OAUTH_TOKEN
    # - bypassPermissionsModeAccepted=true: skip the bypass-permissions acceptance prompt
    #   AND (combined with --dangerously-skip-permissions) skip the workspace trust prompt
    for homedir in /root /home/agent; do
        python3 -c "
import json, os
path = '$homedir/.claude.json'
config = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            config = json.load(f)
    except Exception:
        pass
config['hasCompletedOnboarding'] = True
config['bypassPermissionsModeAccepted'] = True
with open(path, 'w') as f:
    json.dump(config, f, indent=2)
"
    done
    chown agent:agent /home/agent/.claude.json
}

# =============================================================================
# AI Maestro Configuration
# =============================================================================

setup_ai_maestro_data() {
    mkdir -p /data/ai-maestro/agents /data/ai-maestro/logs /data/ai-maestro/teams

    # Clean stale repo files if a previous deploy cloned the repo into the data dir.
    # Only config data (agents/, logs/, teams/, *.json) should live here.
    if [ -f /data/ai-maestro/package.json ]; then
        echo "Cleaning stale repo files from /data/ai-maestro..."
        cd /data/ai-maestro
        find . -maxdepth 1 ! -name '.' ! -name 'agents' ! -name 'logs' ! -name 'teams' \
            ! -name '*.json' ! -name 'amp' -exec rm -rf {} + 2>/dev/null || true
    fi

    # Symlink ~/.aimaestro -> /data/ai-maestro for both users.
    # Force-recreate because AI Maestro may replace the symlink with a real directory.
    rm -rf /root/.aimaestro
    ln -s /data/ai-maestro /root/.aimaestro
    rm -rf /home/agent/.aimaestro
    ln -s /data/ai-maestro /home/agent/.aimaestro
}

setup_ai_maestro_hosts() {
    # Update hosts.json with the current public URL while preserving the
    # organization fields. A full overwrite clears the org and triggers
    # AI Maestro's "Welcome / Create New Network" screen on every deploy.
    python3 -c "
import json, os
path = '/data/ai-maestro/hosts.json'
existing = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            existing = json.load(f)
    except Exception:
        pass
existing['hosts'] = [{
    'id': '$SELF_HOST_ID',
    'name': '$SELF_HOST_ID',
    'url': '$MAESTRO_PUBLIC_URL',
    'enabled': True,
    'description': 'This machine'
}]
with open(path, 'w') as f:
    json.dump(existing, f, indent=2)
" 2>/dev/null || true
}

setup_agent_working_directories() {
    mkdir -p /data/agents
    chown -R agent:agent /data/agents

    # Pre-create working directories for all registered agents
    if [ -f /data/ai-maestro/agents/registry.json ]; then
        python3 -c "
import json, os
try:
    with open('/data/ai-maestro/agents/registry.json') as f:
        agents = json.load(f)
    for agent in agents:
        wd = agent.get('workingDirectory', '')
        if wd and wd.startswith('/data/agents/'):
            os.makedirs(wd, exist_ok=True)
            os.system(f'chown agent:agent {wd}')
except Exception:
    pass
" 2>/dev/null || true
    fi
}

fix_agent_registry() {
    # Fix agent registry entries on each boot:
    #   1. Replace stale private Fly.io IPs (http://172.x.x.x) with the public URL
    #   2. Ensure all agents have --dangerously-skip-permissions in programArgs
    #      (AI Maestro's wake route appends programArgs to the claude command)
    #   3. Remove old --permission-mode bypassPermissions (replaced by above)
    if [ -f /data/ai-maestro/agents/registry.json ]; then
        python3 -c "
import json, sys
try:
    with open('/data/ai-maestro/agents/registry.json') as f:
        agents = json.load(f)
    changed = False
    for agent in agents:
        # Fix stale hostUrl
        if agent.get('hostUrl', '').startswith('http://172.'):
            agent['hostUrl'] = '$MAESTRO_PUBLIC_URL'
            changed = True
        args = agent.get('programArgs', '')
        # Remove old --permission-mode bypassPermissions flag
        if '--permission-mode bypassPermissions' in args:
            args = args.replace('--permission-mode bypassPermissions', '').strip()
            agent['programArgs'] = args
            changed = True
        # Ensure --dangerously-skip-permissions flag is present
        if '--dangerously-skip-permissions' not in args:
            agent['programArgs'] = (args + ' --dangerously-skip-permissions').strip()
            changed = True
    if changed:
        with open('/data/ai-maestro/agents/registry.json', 'w') as f:
            json.dump(agents, f, indent=2)
        print('Updated agent registry (hostUrl + programArgs)')
except Exception as e:
    print(f'Warning: could not fix agent registry: {e}', file=sys.stderr)
" 2>/dev/null || true
    fi
}

# =============================================================================
# Secrets & Environment
# =============================================================================

setup_agent_secrets() {
    # Make secrets available to the agent user's shell sessions.
    # AI Maestro runs as agent, so tmux sessions inherit these.
    # Claude Code and gh CLI read these from the environment.
    cat > /home/agent/.zshenv <<EOF
export CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"
export GH_TOKEN="$GH_TOKEN"
EOF
    chown agent:agent /home/agent/.zshenv
    chmod 600 /home/agent/.zshenv
}

verify_secrets() {
    for var in CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN; do
        if [ -z "${!var}" ]; then
            echo "WARNING: $var is NOT set!"
        else
            echo "OK: $var is set"
        fi
    done
}

# =============================================================================
# Service Launchers
# =============================================================================

start_n8n() {
    echo "Starting n8n on port 5678..."
    export N8N_USER_FOLDER=/data/n8n
    export N8N_PORT=5678
    export N8N_LISTEN_ADDRESS=0.0.0.0
    export N8N_EDITOR_BASE_URL=https://backoffice-automation.fly.dev
    export WEBHOOK_URL=https://backoffice-automation.fly.dev
    export NODES_EXCLUDE=""
    export NODE_PATH=/usr/lib/node_modules:$NODE_PATH

    n8n &
    N8N_PID=$!

    # Give n8n time to start and create its directory structure
    sleep 5

    # If the n8n community node for Claude Code is installed, ensure its
    # dependency on @anthropic-ai/claude-code is satisfied.
    local community_node="/data/n8n/.n8n/nodes/node_modules/@johnlindquist/n8n-nodes-claudecode"
    if [ -d "$community_node" ]; then
        echo "Fixing Claude Code dependency for n8n community node..."
        cd "$community_node"
        if [ ! -d "node_modules/@anthropic-ai/claude-code" ]; then
            npm install @anthropic-ai/claude-code 2>&1 | grep -v "warn" || true
            echo "OK: Claude Code dependency installed"
        else
            echo "OK: Claude Code dependency already present"
        fi
    fi

    # Seed bundled workflows on first boot (CLI import writes to DB;
    # new workflows appear in the UI on refresh)
    if [ ! -f /data/n8n/.workflows-seeded ] && [ -d /opt/workflows ]; then
        echo "Importing seed workflows..."
        for wf in /opt/workflows/*.json; do
            N8N_USER_FOLDER=/data/n8n n8n import:workflow --input="$wf" 2>&1 || true
        done
        touch /data/n8n/.workflows-seeded
        echo "OK: Seed workflows imported (refresh n8n UI to see them)"
    fi
}

start_ai_maestro() {
    # AI Maestro runs as the 'agent' user so that tmux sessions it creates
    # are owned by a non-root user. This is required because Claude Code's
    # --dangerously-skip-permissions is blocked for root/sudo.
    # The agent user's .zshenv provides CLAUDE_CODE_OAUTH_TOKEN and GH_TOKEN,
    # which are inherited by tmux sessions and Claude Code.
    echo "Starting AI Maestro on port 23001 (as agent user)..."
    (
        while true; do
            su - agent -c "cd /opt/ai-maestro && NODE_ENV=production PORT=23001 node server.mjs" 2>&1 | tee -a /data/ai-maestro/logs/maestro.log
            echo "AI Maestro exited ($(date)), restarting in 5s..."
            sleep 5
        done
    ) &
    AI_MAESTRO_PID=$!
}

start_auth_proxy() {
    if [ -n "$GITHUB_OAUTH_CLIENT_ID" ] && [ -n "$GITHUB_OAUTH_CLIENT_SECRET" ]; then
        start_auth_proxy_github_oauth
    elif [ -n "$CADDY_AUTH_PASS" ]; then
        start_auth_proxy_basic_auth
    else
        start_auth_proxy_none
    fi

    caddy run --config /etc/caddy/Caddyfile &
    CADDY_PID=$!
}

start_auth_proxy_github_oauth() {
    echo "Starting auth proxy (GitHub OAuth) on port 23000..."

    if [ -z "$OAUTH2_COOKIE_SECRET" ]; then
        OAUTH2_COOKIE_SECRET=$(openssl rand -base64 32 | head -c 32)
    fi

    oauth2-proxy \
        --provider=github \
        --client-id="$GITHUB_OAUTH_CLIENT_ID" \
        --client-secret="$GITHUB_OAUTH_CLIENT_SECRET" \
        --cookie-secret="$OAUTH2_COOKIE_SECRET" \
        --cookie-secure=true \
        --email-domain="*" \
        --github-user="${GITHUB_OAUTH_ALLOWED_USER:-brandoncasci}" \
        --http-address="127.0.0.1:4180" \
        --redirect-url="https://backoffice-automation.fly.dev:23000/oauth2/callback" \
        --upstream="static://202" \
        --skip-provider-button=true \
        --reverse-proxy=true &
    OAUTH2_PID=$!

    cat > /etc/caddy/Caddyfile <<'CADDYEOF'
:23000 {
    @internal remote_ip 127.0.0.1 ::1 172.16.0.0/12 10.0.0.0/8 192.168.0.0/16 fd00::/8
    handle @internal {
        reverse_proxy 127.0.0.1:23001
    }
    handle {
        handle /oauth2/* {
            reverse_proxy 127.0.0.1:4180
        }
        forward_auth 127.0.0.1:4180 {
            uri /oauth2/auth
            header_up X-Forwarded-Uri {uri}
            copy_headers X-Auth-Request-User X-Auth-Request-Email
        }
        reverse_proxy 127.0.0.1:23001
    }
}
CADDYEOF

    AUTH_MODE="GitHub OAuth"
}

start_auth_proxy_basic_auth() {
    echo "Starting auth proxy (basic auth) on port 23000..."
    CADDY_AUTH_USER="${CADDY_AUTH_USER:-admin}"
    CADDY_HASH=$(caddy hash-password --plaintext "$CADDY_AUTH_PASS")

    cat > /etc/caddy/Caddyfile <<CADDYEOF
:23000 {
    @internal remote_ip 127.0.0.1 ::1 172.16.0.0/12 10.0.0.0/8 192.168.0.0/16 fd00::/8
    handle @internal {
        reverse_proxy 127.0.0.1:23001
    }
    handle {
        basic_auth {
            $CADDY_AUTH_USER $CADDY_HASH
        }
        reverse_proxy 127.0.0.1:23001
    }
}
CADDYEOF

    AUTH_MODE="basic auth (user: $CADDY_AUTH_USER)"
}

start_auth_proxy_none() {
    echo "WARNING: No auth configured for AI Maestro!"
    echo "Set CADDY_AUTH_PASS or GITHUB_OAUTH_CLIENT_ID as Fly secrets."

    cat > /etc/caddy/Caddyfile <<'CADDYEOF'
:23000 {
    reverse_proxy 127.0.0.1:23001
}
CADDYEOF

    AUTH_MODE="NONE (insecure!)"
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo "========================================="
    echo "Backoffice Automation - Starting Services"
    echo "========================================="

    # Phase 1: Configure persistent storage and symlinks
    setup_data_directories
    setup_claude_config
    setup_ai_maestro_data
    setup_ai_maestro_hosts
    setup_agent_working_directories
    fix_agent_registry

    # Phase 2: Environment and secrets
    setup_agent_secrets
    verify_secrets

    # Phase 3: Start services
    start_n8n
    start_ai_maestro
    start_auth_proxy

    # Summary
    echo "========================================="
    echo "All services started:"
    echo "  - n8n (PID: $N8N_PID) on port 5678"
    echo "  - AI Maestro (PID: $AI_MAESTRO_PID) on port 23001 (as agent user)"
    echo "  - Caddy auth proxy (PID: $CADDY_PID) on port 23000 ($AUTH_MODE)"
    echo "========================================="

    # Wait on n8n as the primary process (container exits when this dies)
    echo "Waiting on n8n process..."
    wait $N8N_PID
}

main "$@"
