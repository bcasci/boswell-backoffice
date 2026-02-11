#!/bin/bash
set -e

echo "========================================="
echo "Backoffice Automation - Starting Services"
echo "========================================="

# Ensure /data directory structure exists
echo "Setting up data directories..."
sudo mkdir -p /data/n8n /data/ai-maestro /data/repos /data/worktrees
sudo chown -R agent:agent /data

# Ensure symlinks exist
if [ ! -L /home/agent/.n8n ]; then
    ln -s /data/n8n /home/agent/.n8n
fi

# Set up Claude Code config for agent user (programmatic auth)
if [ ! -d /data/claude ]; then
    mkdir -p /data/claude
    chown agent:agent /data/claude
fi

# Create .claude.json with onboarding completed (required for CLAUDE_CODE_OAUTH_TOKEN to work)
if [ ! -f /data/claude/.claude.json ]; then
    echo '{"hasCompletedOnboarding":true}' > /data/claude/.claude.json
    chown agent:agent /data/claude/.claude.json
fi

# Symlink for agent user
if [ ! -L /home/agent/.claude ]; then
    ln -s /data/claude /home/agent/.claude
fi

# Make secrets available to agent user shell sessions
cat > /home/agent/.zshenv <<EOF
export CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"
export GH_TOKEN="$GH_TOKEN"
EOF
chown agent:agent /home/agent/.zshenv
chmod 600 /home/agent/.zshenv

# Note: SSH access is provided by Fly's built-in SSH (fly ssh console)
# No need to start our own sshd

# Start n8n
echo "Starting n8n on port 5678..."
export N8N_USER_FOLDER=/data/n8n
export N8N_PORT=5678
export N8N_LISTEN_ADDRESS=0.0.0.0
# Make global npm packages accessible to n8n community nodes
export NODE_PATH=/usr/lib/node_modules:$NODE_PATH

# Debug: Check if secrets are available (DO NOT print actual values!)
if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
    echo "WARNING: CLAUDE_CODE_OAUTH_TOKEN is NOT set!"
else
    echo "✓ CLAUDE_CODE_OAUTH_TOKEN is set"
fi

if [ -z "$GH_TOKEN" ]; then
    echo "WARNING: GH_TOKEN is NOT set!"
else
    echo "✓ GH_TOKEN is set"
fi

n8n &
N8N_PID=$!

# Give n8n a moment to start and create directories
sleep 5

# Fix n8n community node if it's installed (make Claude Code available to it)
COMMUNITY_NODE_PATH="/data/n8n/.n8n/nodes/node_modules/@johnlindquist/n8n-nodes-claudecode"
if [ -d "$COMMUNITY_NODE_PATH" ]; then
    echo "Fixing Claude Code dependency for n8n community node..."
    cd "$COMMUNITY_NODE_PATH"
    if [ ! -d "node_modules/@anthropic-ai/claude-code" ]; then
        npm install @anthropic-ai/claude-code 2>&1 | grep -v "warn" || true
        echo "✓ Claude Code dependency installed"
    else
        echo "✓ Claude Code dependency already present"
    fi
fi

# Install and start AI Maestro (runtime installation to keep Docker image small)
if [ ! -d /data/ai-maestro/.git ]; then
    echo "First boot: Installing AI Maestro to /data/ai-maestro..."
    git clone https://github.com/23blocks-OS/ai-maestro.git /data/ai-maestro
    cd /data/ai-maestro
    npm install -g yarn
    yarn install
    echo "✓ AI Maestro installed"
else
    echo "AI Maestro already installed, checking for updates..."
    cd /data/ai-maestro
    git pull || echo "Could not update AI Maestro (offline or no changes)"
fi

echo "Starting AI Maestro..."
cd /data/ai-maestro
export AI_MAESTRO_DATA=/data/ai-maestro
# Run in development mode (no pre-build needed)
yarn dev 2>&1 | grep -v "CUDA" &
AI_MAESTRO_PID=$!

echo "========================================="
echo "All services started:"
echo "  - n8n (PID: $N8N_PID)"
echo "  - AI Maestro (PID: $AI_MAESTRO_PID)"
echo "========================================="
echo "Waiting on n8n process..."

# Wait on n8n (primary service)
wait $N8N_PID
