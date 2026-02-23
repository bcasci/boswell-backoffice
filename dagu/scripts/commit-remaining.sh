#!/bin/bash
# Safety net: commit and push any uncommitted changes Claude left behind.
# Runs after run-claude for all actions. No-op if working tree is clean.
#
# Only stages modified/new files in tracked paths — ignores deletions and
# .claude/work/ artifacts that appear as noise in fresh issue clones.
#
# Reads: /tmp/dagu-work-dir (set by setup-workspace.sh)
set -e

WORK_DIR=$(cat /tmp/dagu-work-dir)
cd "$WORK_DIR"

BRANCH=$(git branch --show-current)

# Don't commit on main/master — something went wrong
if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
    echo "On $BRANCH — skipping safety-net commit"
    exit 0
fi

# Stage only modified (not deleted) tracked files, excluding .claude/work/
CHANGED=$(git diff --name-only --diff-filter=AM -- . ':!.claude/work/')
if [ -z "$CHANGED" ]; then
    echo "No modified files to commit — working tree clean"
    exit 0
fi

echo "Found uncommitted changes on $BRANCH — committing safety net"
echo "$CHANGED"
echo "$CHANGED" | xargs git add
git commit -m "Agent: uncommitted changes (safety net)"
git push origin HEAD
echo "Safety-net commit pushed to $BRANCH"
