#!/bin/bash
set -e

# =============================================================================
# Backoffice Automation Entrypoint
# =============================================================================
# Starts n8n, Dagu, Caddy auth proxy, PostgreSQL, and Redis.
#
# Services:
#   - n8n          → port 5678  (workflow automation, webhook intake)
#   - Dagu         → port 8080  (internal, agent orchestration + web UI)
#   - Caddy        → port 23000 (auth proxy for Dagu dashboard)
#   - PostgreSQL   → socket    (boswell-hub database)
#   - Redis        → port 6379 (Sidekiq job queue)
#
# Dagu runs as the 'agent' user so claude -p subprocesses inherit the
# correct environment (CLAUDE_CODE_OAUTH_TOKEN, GH_TOKEN, asdf paths).
#
# Persistent volume: /data (survives deploys)
#   /data/n8n          - n8n workflows and settings
#   /data/dagu         - Dagu config, DAGs, logs, execution history
#   /data/claude       - Claude Code auth and settings
#   /data/agents       - Agent working directories
#   /data/repos        - Cloned repositories
#   /data/postgres     - PostgreSQL data directory
# =============================================================================

# =============================================================================
# Data & Directory Setup
# =============================================================================

setup_data_directories() {
    echo "Setting up data directories..."
    sudo mkdir -p /data/n8n /data/repos /data/agents \
        /data/dagu/dags /data/dagu/logs
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

setup_claude_plugins() {
    # Install ralph-wiggum plugin for autonomous agent loops.
    # Checks if already installed by looking in the user settings file.
    # The plugin is from the anthropics/claude-code demo marketplace.
    local settings="/data/claude/settings.json"
    if [ -f "$settings" ] && grep -q "ralph-wiggum" "$settings" 2>/dev/null; then
        echo "OK: ralph-wiggum plugin already installed"
    else
        echo "Installing ralph-wiggum plugin..."
        su - agent -c "claude plugin marketplace add anthropics/claude-code" 2>&1 || true
        su - agent -c "claude plugin install ralph-wiggum@claude-code-plugins --scope user" 2>&1 || true
        if grep -q "ralph-wiggum" "$settings" 2>/dev/null; then
            echo "OK: ralph-wiggum plugin installed"
        else
            echo "WARNING: ralph-wiggum plugin install may have failed — verify manually"
        fi
    fi
}

# =============================================================================
# asdf Version Manager
# =============================================================================

setup_asdf() {
    echo "Setting up asdf..."
    mkdir -p /data/asdf
    chown agent:agent /data/asdf

    # Install ruby plugin if missing (plugins live in ASDF_DATA_DIR on persistent volume)
    if [ ! -d /data/asdf/plugins/ruby ]; then
        echo "Installing asdf ruby plugin..."
        su - agent -c "ASDF_DIR=/opt/asdf ASDF_DATA_DIR=/data/asdf /opt/asdf/bin/asdf plugin add ruby" 2>&1 || true
    fi
    echo "OK: asdf configured (ASDF_DATA_DIR=/data/asdf)"
}

bootstrap_ruby_for_repos() {
    # Background task: auto-install Ruby versions and bundle gems for each repo.
    # Reads .tool-versions from each repo to determine required Ruby version.
    # Idempotent — skips if Ruby version already installed and bundle is satisfied.
    echo "RUBY: Starting background Ruby bootstrap..."

    for agent_dir in /data/agents/*/repo; do
        [ -d "$agent_dir" ] || continue
        local agent_name
        agent_name=$(basename "$(dirname "$agent_dir")")

        # Read ruby version from .tool-versions
        if [ ! -f "$agent_dir/.tool-versions" ]; then
            echo "RUBY: $agent_name — no .tool-versions, skipping"
            continue
        fi
        local ruby_version
        ruby_version=$(grep '^ruby ' "$agent_dir/.tool-versions" 2>/dev/null | awk '{print $2}')
        if [ -z "$ruby_version" ]; then
            echo "RUBY: $agent_name — no ruby in .tool-versions, skipping"
            continue
        fi

        # Install Ruby if not already present (check for actual binary, not just directory)
        if [ -x "/data/asdf/installs/ruby/$ruby_version/bin/ruby" ]; then
            echo "RUBY: $agent_name — ruby $ruby_version already installed, skipping"
        else
            # Clean up any partial install
            rm -rf "/data/asdf/installs/ruby/$ruby_version"
            echo "RUBY: $agent_name — installing ruby $ruby_version (this may take 10-20 min)..."
            su - agent -c "ASDF_DIR=/opt/asdf ASDF_DATA_DIR=/data/asdf MAKE_OPTS='-j1' /opt/asdf/bin/asdf install ruby $ruby_version" 2>&1 | \
                while IFS= read -r line; do echo "RUBY: $line"; done
            if [ -x "/data/asdf/installs/ruby/$ruby_version/bin/ruby" ]; then
                echo "RUBY: $agent_name — ruby $ruby_version installed successfully"
            else
                echo "RUBY: $agent_name — ruby $ruby_version install FAILED"
                continue
            fi
        fi

        # Ensure shims and global version are set
        su - agent -c "ASDF_DIR=/opt/asdf ASDF_DATA_DIR=/data/asdf /opt/asdf/bin/asdf reshim ruby $ruby_version" 2>/dev/null || true
        su - agent -c "ASDF_DIR=/opt/asdf ASDF_DATA_DIR=/data/asdf /opt/asdf/bin/asdf global ruby $ruby_version" 2>/dev/null || true

        # Bundle install if needed
        echo "BUNDLE: $agent_name — checking bundle..."
        if su - agent -c "cd $agent_dir && bundle check" >/dev/null 2>&1; then
            echo "BUNDLE: $agent_name — bundle satisfied, skipping"
        else
            echo "BUNDLE: $agent_name — running bundle install..."
            su - agent -c "cd $agent_dir && gem install bundler && bundle install" 2>&1 | \
                while IFS= read -r line; do echo "BUNDLE: $line"; done
            echo "BUNDLE: $agent_name — bundle install complete"
        fi
    done

    echo "RUBY: Background bootstrap complete"
}

bootstrap_hub_tests() {
    # Prepare boswell-hub for running tests on the VPS.
    # Patches database.yml (macOS socket path → Linux) and runs db:prepare.
    # This is the ONLY source file modification — everything else is env config.
    local hub_dir="/data/agents/boswell-hub-manager/repo"

    if [ ! -d "$hub_dir/.git" ]; then
        echo "HUB-BOOTSTRAP: repo not cloned yet, skipping"
        return 0
    fi

    # Write Rails master key to config/master.key (per-repo, not global env).
    # This file is in .gitignore — it's a per-machine credential, not a source patch.
    # Uses BOSWELL_HUB_MASTER_KEY (qualified name) so each app has its own secret.
    # Fallback to RAILS_MASTER_KEY for backward compat during migration.
    local hub_key="${BOSWELL_HUB_MASTER_KEY:-$RAILS_MASTER_KEY}"
    if [ -n "$hub_key" ] && [ ! -f "$hub_dir/config/master.key" ]; then
        echo -n "$hub_key" > "$hub_dir/config/master.key"
        chown agent:agent "$hub_dir/config/master.key"
        chmod 600 "$hub_dir/config/master.key"
        echo "HUB-BOOTSTRAP: Wrote config/master.key"
    fi

    # Enable dev caching (same as running 'rails dev:cache' locally).
    # Required because development.rb checks for this before loading auth0 session config.
    # This file is in .gitignore — it's a per-machine toggle, not a source patch.
    mkdir -p "$hub_dir/tmp"
    touch "$hub_dir/tmp/caching-dev.txt"

    # Patch database.yml: replace macOS socket path with Linux default
    local db_yml="$hub_dir/config/database.yml"
    if [ -f "$db_yml" ] && grep -q '/Users/brandoncasci/.asdf/installs/postgres/12.1/sockets' "$db_yml"; then
        echo "HUB-BOOTSTRAP: Patching database.yml socket path..."
        sed -i 's|/Users/brandoncasci/.asdf/installs/postgres/12.1/sockets|/var/run/postgresql|g' "$db_yml"
        echo "HUB-BOOTSTRAP: database.yml patched"
    else
        echo "HUB-BOOTSTRAP: database.yml already patched or not present, skipping"
    fi

    # Prepare development database (Rails default env)
    echo "HUB-BOOTSTRAP: Running db:prepare (development)..."
    su - agent -c "cd $hub_dir && bundle exec rails db:prepare" 2>&1 | \
        while IFS= read -r line; do echo "HUB-BOOTSTRAP: $line"; done

    # Prepare test database
    echo "HUB-BOOTSTRAP: Running db:prepare (test)..."
    su - agent -c "cd $hub_dir && RAILS_ENV=test bundle exec rails db:prepare" 2>&1 | \
        while IFS= read -r line; do echo "HUB-BOOTSTRAP: $line"; done

    echo "HUB-BOOTSTRAP: Bootstrap complete"
}

# =============================================================================
# Dagu Configuration
# =============================================================================

setup_agent_working_directories() {
    mkdir -p /data/agents
    chown -R agent:agent /data/agents

    # Directory layout per agent:
    #   /data/agents/<name>/repo/      ← git clone (main branch, spec work, worktree source)
    #   /data/agents/<name>/issues/    ← git worktrees (one per issue)
    #
    # AI Maestro workingDirectory points to repo/ so Claude Code starts with
    # full project context (.claude/ commands). Dispatcher cd's to worktrees.

    # Migrate legacy layout: if repo was cloned at agent root, move to repo/ subdir
    migrate_repo_to_subdir() {
        local agent_root="$1"
        if [ -d "$agent_root/.git" ] && [ ! -d "$agent_root/repo" ]; then
            echo "Migrating $agent_root to repo/ subdirectory layout..."
            local tmp_dir="/tmp/repo-migrate-$$"
            mv "$agent_root" "$tmp_dir"
            mkdir -p "$agent_root"
            mv "$tmp_dir" "$agent_root/repo"
            chown -R agent:agent "$agent_root"
            echo "OK: Migrated $agent_root → $agent_root/repo/"
        fi
    }

    migrate_repo_to_subdir "/data/agents/boswell-hub-manager"
    migrate_repo_to_subdir "/data/agents/boswell-app-manager"

    # Clone repos into agent repo/ directories if not already present.
    # Runs as agent user so git config and file ownership are correct.
    clone_repo_if_missing() {
        local repo_url="$1"
        local agent_root="$2"
        local target_dir="$agent_root/repo"
        mkdir -p "$agent_root"
        if [ ! -d "$target_dir/.git" ]; then
            echo "Cloning $repo_url into $target_dir..."
            su - agent -c "git clone https://x-access-token:${GH_TOKEN}@github.com/${repo_url}.git $target_dir" 2>&1
            echo "OK: Cloned $repo_url"
        else
            echo "OK: $target_dir already has repo"
        fi
    }

    clone_repo_if_missing "teamboswell/boswell-hub" "/data/agents/boswell-hub-manager"
    clone_repo_if_missing "teamboswell/boswell-app" "/data/agents/boswell-app-manager"

    # Create issues/ directories for worktrees
    mkdir -p /data/agents/boswell-hub-manager/issues /data/agents/boswell-app-manager/issues
    chown -R agent:agent /data/agents/
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
export BOSWELL_HUB_MASTER_KEY="$BOSWELL_HUB_MASTER_KEY"

# asdf version manager (Ruby, Node.js, etc.)
# PATH-only setup avoids sourcing asdf.sh which prints a noisy v0.16 migration notice.
# Shims handle version switching via .tool-versions automatically.
export ASDF_DIR=/opt/asdf
export ASDF_DATA_DIR=/data/asdf
export PATH="\$ASDF_DATA_DIR/shims:\$ASDF_DIR/bin:\$PATH"

# Use jemalloc for Ruby (better memory usage on constrained VPS)
export LD_PRELOAD=libjemalloc.so.2
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
# PostgreSQL & Redis
# =============================================================================

setup_postgres() {
    echo "Setting up PostgreSQL..."
    local pgdata="/data/postgres"

    # Initialize data directory on first boot
    if [ ! -f "$pgdata/PG_VERSION" ]; then
        echo "POSTGRES: Initializing data directory at $pgdata..."
        mkdir -p "$pgdata"
        chown postgres:postgres "$pgdata"
        su -s /bin/bash postgres -c "/usr/lib/postgresql/*/bin/initdb -D $pgdata" 2>&1
        echo "POSTGRES: Data directory initialized"
    else
        # Ensure ownership is correct (may have been created by root in a previous version)
        chown -R postgres:postgres "$pgdata"
        echo "POSTGRES: Data directory already exists, skipping initdb"
    fi

    # Start PostgreSQL
    echo "POSTGRES: Starting server..."
    su -s /bin/bash postgres -c "/usr/lib/postgresql/*/bin/pg_ctl -D $pgdata -l /data/postgres/server.log start" 2>&1

    # Wait for PostgreSQL to be ready
    local retries=0
    while ! pg_isready -q 2>/dev/null; do
        retries=$((retries + 1))
        if [ $retries -gt 30 ]; then
            echo "POSTGRES: ERROR — server did not start within 30 seconds"
            return 1
        fi
        sleep 1
    done
    echo "POSTGRES: Server is ready"

    # Create agent superuser role if not exists
    if ! su -s /bin/bash postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='agent'\"" 2>/dev/null | grep -q 1; then
        su -s /bin/bash postgres -c "createuser -s agent" 2>&1
        echo "POSTGRES: Created 'agent' superuser role"
    else
        echo "POSTGRES: 'agent' role already exists"
    fi
}

start_redis() {
    echo "Starting Redis..."
    redis-server --daemonize yes 2>&1
    echo "OK: Redis started"
}

# =============================================================================
# Service Launchers
# =============================================================================

sync_workflows() {
    # Sync baked-in workflow JSONs with n8n database.
    # Runs BEFORE n8n starts so changes are picked up immediately.
    # Compares nodes content by hash; updates both workflow_entity and workflow_history.
    if [ ! -f /data/n8n/.n8n/database.sqlite ] || [ ! -d /opt/workflows ]; then
        return
    fi
    echo "Syncing workflows from Docker image..."
    python3 -c "
import sqlite3, json, hashlib, os, glob

DB = '/data/n8n/.n8n/database.sqlite'
WF_DIR = '/opt/workflows'

conn = sqlite3.connect(DB)
cur = conn.cursor()
updated = 0

for wf_path in glob.glob(os.path.join(WF_DIR, '*.json')):
    with open(wf_path) as f:
        baked = json.load(f)
    baked_nodes = json.dumps(baked.get('nodes', []), sort_keys=True)
    baked_hash = hashlib.sha256(baked_nodes.encode()).hexdigest()
    wf_name = baked.get('name', '')
    if not wf_name:
        continue

    cur.execute('SELECT id, nodes FROM workflow_entity WHERE name = ?', (wf_name,))
    row = cur.fetchone()
    if not row:
        continue
    wf_id, db_nodes_json = row
    db_hash = hashlib.sha256(
        json.dumps(json.loads(db_nodes_json), sort_keys=True).encode()
    ).hexdigest()

    if baked_hash == db_hash:
        continue

    # Update workflow_entity
    new_nodes = json.dumps(baked.get('nodes', []))
    new_connections = json.dumps(baked.get('connections', {}))
    cur.execute('UPDATE workflow_entity SET nodes = ?, connections = ? WHERE id = ?',
                (new_nodes, new_connections, wf_id))

    # Update ALL workflow_history entries
    cur.execute('SELECT versionId FROM workflow_history WHERE workflowId = ?', (wf_id,))
    for (vid,) in cur.fetchall():
        cur.execute('UPDATE workflow_history SET nodes = ?, connections = ? WHERE versionId = ?',
                    (new_nodes, new_connections, vid))
    updated += 1
    print(f'  Synced: {wf_name}')

conn.commit()
conn.close()
if updated:
    print(f'OK: Synced {updated} workflow(s) from Docker image')
else:
    print('OK: All workflows up to date')
" 2>&1 || echo "Warning: workflow sync failed (non-fatal)"
}

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

start_dagu() {
    # Dagu runs as the 'agent' user so claude -p subprocesses inherit
    # the agent's environment (tokens, asdf paths, jemalloc preload).
    echo "Starting Dagu on port 8080 (as agent user, localhost only)..."

    # Copy baked-in DAGs to persistent volume (don't overwrite user edits)
    cp -n /opt/dagu/dags/*.yaml /data/dagu/dags/ 2>/dev/null || true
    # But always update the agent-dispatch DAG to latest version
    cp /opt/dagu/dags/agent-dispatch.yaml /data/dagu/dags/agent-dispatch.yaml 2>/dev/null || true

    # Copy config (always overwrite with latest from image)
    cp /opt/dagu/config.yaml /data/dagu/config.yaml

    chown -R agent:agent /data/dagu

    (
        while true; do
            su - agent -c "dagu start-all --config /data/dagu/config.yaml" 2>&1 | tee -a /data/dagu/logs/dagu.log
            echo "Dagu exited ($(date)), restarting in 5s..."
            sleep 5
        done
    ) &
    DAGU_PID=$!
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
        reverse_proxy 127.0.0.1:8080
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
        reverse_proxy 127.0.0.1:8080
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
        reverse_proxy 127.0.0.1:8080
    }
    handle {
        basic_auth {
            $CADDY_AUTH_USER $CADDY_HASH
        }
        reverse_proxy 127.0.0.1:8080
    }
}
CADDYEOF

    AUTH_MODE="basic auth (user: $CADDY_AUTH_USER)"
}

start_auth_proxy_none() {
    echo "WARNING: No auth configured for Dagu dashboard!"
    echo "Set CADDY_AUTH_PASS or GITHUB_OAUTH_CLIENT_ID as Fly secrets."

    cat > /etc/caddy/Caddyfile <<'CADDYEOF'
:23000 {
    reverse_proxy 127.0.0.1:8080
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
    setup_claude_plugins
    setup_asdf
    setup_agent_working_directories

    # Phase 2: Environment and secrets
    setup_agent_secrets
    verify_secrets

    # Phase 3: Start data services (needed before app bootstrap)
    setup_postgres
    start_redis

    # Phase 4: Start application services
    sync_workflows
    start_n8n
    start_dagu
    start_auth_proxy

    # Phase 5: Background tasks (non-blocking)
    # Ruby bootstrap runs first, then hub test bootstrap chains after it.
    # set +e so failures in bootstrap don't kill the container (set -e inherited by subshells).
    (
        set +e
        bootstrap_ruby_for_repos
        bootstrap_hub_tests
    ) &

    # Summary
    echo "========================================="
    echo "All services started:"
    echo "  - n8n (PID: $N8N_PID) on port 5678"
    echo "  - Dagu (PID: $DAGU_PID) on port 8080 (as agent user, localhost only)"
    echo "  - Caddy auth proxy (PID: $CADDY_PID) on port 23000 ($AUTH_MODE)"
    echo "  - PostgreSQL on /var/run/postgresql"
    echo "  - Redis on port 6379"
    echo "========================================="

    # Wait on n8n as the primary process (container exits when this dies)
    echo "Waiting on n8n process..."
    wait $N8N_PID
}

main "$@"
