#!/bin/bash
# Claude Code skill: /fix-github-issue
# Usage: /fix-github-issue <issue_number>
#
# Reads a GitHub issue, creates a branch, writes failing test, implements fix (TDD),
# runs tests, commits, and opens a PR.

set -e

ISSUE_NUMBER=$1

if [ -z "$ISSUE_NUMBER" ]; then
    echo "Usage: /fix-github-issue <issue_number>"
    exit 1
fi

# Get repo from git remote
REPO=$(git remote get-url origin | sed 's/.*github.com[:/]\(.*\)\.git/\1/')

echo "Fixing issue #$ISSUE_NUMBER in $REPO..."

# Prompt for Claude Code agent
cat <<EOF
You are tasked with fixing GitHub issue #$ISSUE_NUMBER following TDD practices.

**Steps:**

1. **Read the issue**: Run \`gh issue view $ISSUE_NUMBER --repo $REPO\`
2. **Understand the problem**: Analyze the issue description and identify affected files
3. **Create branch**: \`git checkout -b fix/issue-$ISSUE_NUMBER\`
4. **Write failing test**: Create a test that reproduces the bug
5. **Verify test fails**: Run the test suite
6. **Implement fix**: Make minimal changes to fix the bug
7. **Verify tests pass**: Run the full test suite
8. **Commit**: \`git commit -m "fix: <description> (fixes #$ISSUE_NUMBER)"\`
9. **Push**: \`git push -u origin fix/issue-$ISSUE_NUMBER\`
10. **Create PR**: \`gh pr create --title "Fix: <issue title>" --body "Fixes #$ISSUE_NUMBER" --repo $REPO\`

**Requirements:**
- Follow the project's CLAUDE.md conventions
- Use TDD: test first, implementation second
- Run all tests before committing
- Use conventional commit format
- Link PR to issue

Begin by reading the issue.
EOF
