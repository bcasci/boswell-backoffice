# Implement Feature Playbook

This playbook guides Claude Code through implementing a feature using BDD/TDD approach.

## Prerequisites
- GitHub issue number with feature description
- Repository path in /data/repos/

## Checklist

- [ ] Read the feature request: `gh issue view {issue_number} --repo teamboswell/{repo}`
- [ ] Review relevant codebase context to understand where the feature fits
- [ ] Create a new branch: `git checkout -b feature/issue-{issue_number}`
- [ ] Write behavior specifications (BDD style) as tests
- [ ] Run test suite to confirm new tests fail
- [ ] Implement the feature incrementally, following project patterns
- [ ] Run test suite after each increment to ensure tests pass
- [ ] Add any necessary documentation or comments
- [ ] Verify all tests pass
- [ ] Commit changes: `feat: {brief description} (closes #{issue_number})`
- [ ] Push the branch: `git push -u origin feature/issue-{issue_number}`
- [ ] Create PR: `gh pr create --title "Feature: {issue title}" --body "Closes #{issue_number}\\n\\n## Summary\\n{summary}\\n\\n## Test Plan\\n- [ ] {test item}" --repo teamboswell/{repo}`

## Notes
- Use BDD/TDD approach (Jason Swett's behavior-driven testing)
- Follow project's CLAUDE.md standards
- Keep commits focused and atomic
