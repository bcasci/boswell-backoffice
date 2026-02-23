#!/bin/bash
# Run Claude Code in the prepared workspace.
#
# - implement: piped interactive mode with /dev-start slash command
# - comment:   piped interactive mode with XML-wrapped user request
# - spec, pr_opened, etc.: claude -p with trusted n8n-constructed prompt
#
# Env vars: ACTION, REPO, ISSUE_NUM, MESSAGE_B64 (base64-encoded prompt)
# Reads: /tmp/dagu-work-dir (set by setup-workspace.sh)
set -e

WORK_DIR=$(cat /tmp/dagu-work-dir)
cd "$WORK_DIR"

SYSTEM_PROMPT="/opt/dagu/scripts/agent-system-prompt.txt"

# Decode base64-encoded message (avoids space/quote issues in Dagu params)
MESSAGE=$(echo "${MESSAGE_B64}" | base64 -d)

echo "Working directory: $WORK_DIR"
echo "Action: $ACTION"

if [ "$ACTION" = "implement" ]; then
    # Piped interactive mode — /dev-start handles TDD, commits, PR creation.
    SLASH_CMD="/dev-start ${REPO}#${ISSUE_NUM}"
    echo "Invoking slash command: $SLASH_CMD"
    echo "$SLASH_CMD" | claude --dangerously-skip-permissions 2>&1

elif [ "$ACTION" = "comment" ]; then
    # Piped interactive mode with XML boundaries — supports slash commands,
    # isolates untrusted user input, system prompt enforces commit/push.
    BRANCH=$(git branch --show-current)
    echo "Handling @agent comment on branch: $BRANCH"
    cat <<PROMPT | claude --append-system-prompt-file "$SYSTEM_PROMPT" --dangerously-skip-permissions 2>&1
<context>
Repository: ${REPO}
Issue: #${ISSUE_NUM}
Branch: ${BRANCH}
</context>

<user_request>
${MESSAGE}
</user_request>

Carry out the request described in <user_request>. Follow your system directives.
PROMPT

else
    # spec, pr_opened, etc. — trusted prompts constructed by n8n.
    echo "Running claude -p with prompt"
    echo "Prompt: $MESSAGE"
    claude -p "$MESSAGE" --dangerously-skip-permissions 2>&1
fi

EXIT_CODE=$?
echo "Claude exited with code $EXIT_CODE"
exit $EXIT_CODE
