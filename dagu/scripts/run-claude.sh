#!/bin/bash
# Run claude -p with the decoded prompt in the prepared workspace.
#
# Env vars: MESSAGE_B64 (base64-encoded prompt)
# Reads: /tmp/dagu-work-dir (set by setup-workspace.sh)
set -e

WORK_DIR=$(cat /tmp/dagu-work-dir)
cd "$WORK_DIR"

# Decode base64-encoded message (avoids space/quote issues in Dagu params)
MESSAGE=$(echo "${MESSAGE_B64}" | base64 -d)

echo "Running claude -p in $WORK_DIR"
echo "Prompt: $MESSAGE"

# claude -p runs to completion and exits. No tmux, no idle detection needed.
claude -p "$MESSAGE" --dangerously-skip-permissions 2>&1

EXIT_CODE=$?
echo "claude -p exited with code $EXIT_CODE"
exit $EXIT_CODE
