#!/bin/bash
# Post-Deploy Setup Script
# Run this via: fly ssh console -a backoffice-automation
# Then: bash /scripts/post-deploy-setup.sh

set -e

echo "========================================="
echo "Post-Deploy Setup"
echo "========================================="

# Verify auth tokens are set
echo "Checking authentication..."

if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
    echo "ERROR: CLAUDE_CODE_OAUTH_TOKEN not set!"
    echo "Run: fly secrets set CLAUDE_CODE_OAUTH_TOKEN=<token> -a backoffice-automation"
    exit 1
fi

if [ -z "$GH_TOKEN" ]; then
    echo "ERROR: GH_TOKEN not set!"
    echo "Run: fly secrets set GH_TOKEN=<github-pat> -a backoffice-automation"
    exit 1
fi

echo "✓ Environment variables configured"

# Test Claude Code auth
echo ""
echo "Testing Claude Code authentication..."
if claude -p "echo 'Claude Code auth test successful'" > /tmp/claude-test.log 2>&1; then
    echo "✓ Claude Code authenticated successfully"
else
    echo "✗ Claude Code authentication failed!"
    cat /tmp/claude-test.log
    exit 1
fi

# Test GitHub CLI auth
echo ""
echo "Testing GitHub CLI authentication..."
if gh auth status > /tmp/gh-test.log 2>&1; then
    echo "✓ GitHub CLI authenticated successfully"
else
    echo "✗ GitHub CLI authentication failed!"
    cat /tmp/gh-test.log
    exit 1
fi

# Clone target repositories
echo ""
echo "Cloning target repositories..."
cd /data/repos

if [ ! -d "boswell-hub" ]; then
    echo "Cloning teamboswell/boswell-hub..."
    gh repo clone teamboswell/boswell-hub
    echo "✓ boswell-hub cloned"
else
    echo "✓ boswell-hub already exists"
fi

if [ ! -d "boswell-app" ]; then
    echo "Cloning teamboswell/boswell-app..."
    gh repo clone teamboswell/boswell-app
    echo "✓ boswell-app cloned"
else
    echo "✓ boswell-app already exists"
fi

# Note: CCPM should be committed to the repos themselves
# If the repos don't have CCPM, install it locally and commit it to git

echo ""
echo "========================================="
echo "Post-Deploy Setup Complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Access n8n at https://backoffice-automation.fly.dev"
echo "2. Complete n8n first-time setup wizard"
echo "3. Install community node: @johnlindquist/n8n-nodes-claudecode"
echo "4. Import workflows from /workflows/"
echo "5. Configure n8n credentials (GitHub, email, etc.)"
echo "6. Access AI Maestro dashboard at https://backoffice-automation.fly.dev:23000"
echo ""
