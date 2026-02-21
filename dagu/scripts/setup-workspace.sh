#!/bin/bash
# Set up workspace for an agent dispatch job.
# Creates issue clone with proper branch, guardrails, and repo-specific extras.
#
# Env vars: AGENT_NAME, REPO, ISSUE_NUM, NEEDS_WORKTREE, BOSWELL_HUB_MASTER_KEY
# Output: writes WORK_DIR to /tmp/dagu-work-dir
set -e

AGENT_ROOT="/data/agents/${AGENT_NAME}"
REPO_DIR="$AGENT_ROOT/repo"
WT_PATH="$AGENT_ROOT/issues/issue-${ISSUE_NUM}"

git config --global --add safe.directory '*' 2>/dev/null

# Refresh main repo
DEFAULT_BRANCH=$(git -C "$REPO_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="master"
git -C "$REPO_DIR" checkout "$DEFAULT_BRANCH" 2>/dev/null || true
git -C "$REPO_DIR" fetch origin 2>&1
git -C "$REPO_DIR" pull --ff-only 2>/dev/null || true

WORK_DIR="$REPO_DIR"

if [ "${NEEDS_WORKTREE}" = "true" ] || [ "${NEEDS_WORKTREE}" = "True" ]; then
  rm -rf "$WT_PATH"
  GITHUB_URL=$(git -C "$REPO_DIR" remote get-url origin)
  git clone "$REPO_DIR" "$WT_PATH" 2>&1
  git -C "$WT_PATH" remote set-url origin "$GITHUB_URL"
  git -C "$WT_PATH" fetch origin 2>&1

  git -C "$WT_PATH" checkout "issue/${ISSUE_NUM}" 2>/dev/null || \
    git -C "$WT_PATH" checkout -b "issue/${ISSUE_NUM}" "origin/$DEFAULT_BRANCH" 2>&1

  BRANCH_CHECK=$(git -C "$WT_PATH" rev-parse --abbrev-ref HEAD)
  if [ "$BRANCH_CHECK" = "master" ] || [ "$BRANCH_CHECK" = "main" ]; then
    echo "ERROR: branch checkout failed (still on $BRANCH_CHECK)"
    exit 1
  fi

  rm -rf "$WT_PATH/.claude/work" 2>/dev/null
  git -C "$WT_PATH" config --local gh.default-repo "${REPO}" 2>/dev/null
  cd "$WT_PATH" && gh repo set-default "${REPO}" 2>/dev/null || true

  cat >> "$WT_PATH/CLAUDE.md" << 'GUARDRAILS'

## Agent Guardrails (auto-injected by dispatcher)

- **NEVER create or switch branches.** Work on whatever branch you are on when the session starts.
- **If you are on main or master, STOP.** Do not proceed - report the error and exit.
- **NEVER merge pull requests.** Only create PRs and leave them for human review.
- **NEVER close or resolve issues.** Only reference them in PR descriptions.
GUARDRAILS
  echo "- **This repository is: ${REPO}.** Always use \`--repo ${REPO}\` with gh CLI commands, or omit --repo to use the configured default." >> "$WT_PATH/CLAUDE.md"

  # boswell-hub extras: master.key, dev caching, database.yml patch
  if [ "${AGENT_NAME}" = "boswell-hub-manager" ] && [ -n "${BOSWELL_HUB_MASTER_KEY}" ]; then
    echo -n "${BOSWELL_HUB_MASTER_KEY}" > "$WT_PATH/config/master.key"
    chmod 600 "$WT_PATH/config/master.key"
    mkdir -p "$WT_PATH/tmp"
    touch "$WT_PATH/tmp/caching-dev.txt"
    sed -i 's|/Users/brandoncasci/.asdf/installs/postgres/12.1/sockets|/var/run/postgresql|g' "$WT_PATH/config/database.yml" 2>/dev/null || true
  fi

  chown -R agent:agent "$WT_PATH"
  WORK_DIR="$WT_PATH"

elif [ "${NEEDS_WORKTREE}" = "if_exists" ] && [ -d "$WT_PATH" ]; then
  WORK_DIR="$WT_PATH"
fi

echo "$WORK_DIR" > /tmp/dagu-work-dir
echo "WORKSPACE: $WORK_DIR (branch: $(git -C "$WORK_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'n/a'))"
