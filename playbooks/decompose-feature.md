# Decompose Feature Playbook (CCPM)

This playbook uses CCPM commands to decompose a large feature spec into parallelizable tasks.

## Prerequisites
- GitHub issue labeled "feature-spec" with PRD/specification
- Repository has CCPM installed (.claude/commands/pm/)
- Repository path in /data/repos/

## Checklist

- [ ] Read the feature spec: `gh issue view {issue_number} --repo teamboswell/{repo}`
- [ ] Navigate to repo: `cd /data/repos/{repo}`
- [ ] Create a new PRD: `claude -p "/pm:prd-new {issue_number}"`
- [ ] Parse the PRD: `claude -p "/pm:prd-parse"`
- [ ] Decompose into epic tasks: `claude -p "/pm:epic-decompose"`
- [ ] Sync tasks to GitHub: `claude -p "/pm:epic-sync"`
- [ ] Start parallel execution: `claude -p "/pm:epic-start"`
- [ ] Monitor progress (periodically): `claude -p "/pm:epic-status"`
- [ ] When all tasks complete, merge: `claude -p "/pm:epic-merge"`

## Notes
- CCPM handles parallel task execution via worktrees
- Each subtask gets its own branch and PR
- The epic-merge command creates a final integration PR
- Requires CCPM to be installed in the target repo
