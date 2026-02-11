# Fix Bug Playbook

This playbook guides Claude Code through fixing a bug reported in a GitHub issue using TDD approach.

## Prerequisites
- GitHub issue number
- Repository path in /data/repos/

## Checklist

- [ ] Read the GitHub issue details using `gh issue view {issue_number} --repo teamboswell/{repo}`
- [ ] Analyze the issue and identify the affected files
- [ ] Create a new branch: `git checkout -b fix/issue-{issue_number}`
- [ ] Write a failing test that reproduces the bug
- [ ] Run the test suite to confirm the test fails
- [ ] Implement the fix following the project's coding standards
- [ ] Run the test suite to confirm all tests pass
- [ ] Commit the changes with conventional commit format: `fix: {brief description} (fixes #{issue_number})`
- [ ] Push the branch: `git push -u origin fix/issue-{issue_number}`
- [ ] Create a pull request: `gh pr create --title "Fix: {issue title}" --body "Fixes #{issue_number}" --repo teamboswell/{repo}`
- [ ] Link the PR to the issue

## Notes
- Follow the project's CLAUDE.md conventions
- Ensure all tests pass before creating PR
- Use TDD: test first, then implementation
