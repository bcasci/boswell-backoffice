#!/bin/bash
# Run Claude Code in the prepared workspace.
#
# For lifecycle events (implement): uses piped interactive mode so slash
# commands like /dev-start are recognized.
# For other actions (spec, comment): uses claude -p with a text prompt.
#
# Env vars: ACTION, REPO, ISSUE_NUM, MESSAGE_B64 (base64-encoded prompt)
# Reads: /tmp/dagu-work-dir (set by setup-workspace.sh)
set -e

WORK_DIR=$(cat /tmp/dagu-work-dir)
cd "$WORK_DIR"

# Decode base64-encoded message (avoids space/quote issues in Dagu params)
MESSAGE=$(echo "${MESSAGE_B64}" | base64 -d)

echo "Working directory: $WORK_DIR"
echo "Action: $ACTION"

if [ "$ACTION" = "implement" ]; then
    # Use piped interactive mode — slash commands are recognized.
    # /dev-start reads the issue, implements with TDD, commits, pushes, opens PR.
    SLASH_CMD="/dev-start ${REPO}#${ISSUE_NUM}"
    echo "Invoking slash command: $SLASH_CMD"
    echo "$SLASH_CMD" | claude --dangerously-skip-permissions 2>&1
else
    # For spec, comment, pr_opened, etc. — use claude -p with the text prompt.
    echo "Running claude -p with prompt"
    echo "Prompt: $MESSAGE"
    claude -p "$MESSAGE" --dangerously-skip-permissions 2>&1
fi

EXIT_CODE=$?
echo "Claude exited with code $EXIT_CODE"
exit $EXIT_CODE
