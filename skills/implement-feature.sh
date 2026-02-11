#!/bin/bash
# Claude Code skill: /implement-feature
# Usage: /implement-feature <issue_number>
#
# Reads a feature request issue, implements it using BDD/TDD, and opens a PR.

set -e

ISSUE_NUMBER=$1

if [ -z "$ISSUE_NUMBER" ]; then
    echo "Usage: /implement-feature <issue_number>"
    exit 1
fi

# Get repo from git remote
REPO=$(git remote get-url origin | sed 's/.*github.com[:/]\(.*\)\.git/\1/')

echo "Implementing feature from issue #$ISSUE_NUMBER in $REPO..."

# Prompt for Claude Code agent
cat <<EOF
You are tasked with implementing a feature from GitHub issue #$ISSUE_NUMBER using BDD/TDD.

**Steps:**

1. **Read the feature request**: \`gh issue view $ISSUE_NUMBER --repo $REPO\`
2. **Review context**: Understand where this feature fits in the codebase
3. **Create branch**: \`git checkout -b feature/issue-$ISSUE_NUMBER\`
4. **Write behavior specs**: Create tests that describe the desired behavior (BDD style)
5. **Verify tests fail**: Run the test suite
6. **Implement incrementally**: Build the feature step-by-step, running tests frequently
7. **Verify all tests pass**: Run the full test suite
8. **Commit**: \`git commit -m "feat: <description> (closes #$ISSUE_NUMBER)"\`
9. **Push**: \`git push -u origin feature/issue-$ISSUE_NUMBER\`
10. **Create PR**: \`gh pr create --title "Feature: <issue title>" --body "Closes #$ISSUE_NUMBER\n\n## Summary\n<summary>\n\n## Test Plan\n- [ ] <test items>" --repo $REPO\`

**Requirements:**
- Follow Jason Swett's behavior-driven testing approach
- Follow the project's CLAUDE.md conventions
- Write tests first (BDD/TDD)
- Keep commits focused and atomic
- Ensure all tests pass
- Create detailed PR description with test plan

Begin by reading the issue.
EOF
