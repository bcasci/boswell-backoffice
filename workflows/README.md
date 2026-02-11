# n8n Workflow Templates

These workflow JSON files can be imported into n8n after deployment.

## Import Instructions

1. Access n8n at `https://backoffice-automation.fly.dev`
2. Go to Workflows → Import from File
3. Select each JSON file to import
4. Configure credentials for each workflow:
   - **GitHub**: Use GH_TOKEN (set as Fly secret, available as env var)
   - **Email**: IMAP/SMTP credentials (set in n8n UI)
   - **Slack**: Bot token (if using Slack notifications)
   - **Sentry**: API token (if using Sentry integration)

## Required n8n Community Node

**Before importing these workflows**, install the Claude Code community node:

1. Go to Settings → Community Nodes
2. Install: `@johnlindquist/n8n-nodes-claudecode`
3. Restart n8n if prompted

## Workflows

### 1. email-triage.json
Monitors incoming email, classifies with Claude Code, creates GitHub issues for bugs/features.

### 2. sentry-bug-fix.json
Receives Sentry error webhooks, creates GitHub issues, triggers Maestro fix-bug playbook.

### 3. github-auto-implementation.json
Watches for GitHub issues labeled "auto", triggers Maestro implementation playbook.

### 4. feature-decomposition.json
Watches for issues labeled "feature-spec", runs CCPM commands to decompose into tasks.

### 5. daily-digest.json
Cron job (8am daily) that summarizes open issues/PRs and sends notification.

## Credential Setup

All workflows require GitHub authentication. The `GH_TOKEN` environment variable (from Fly secrets) should be used in n8n's GitHub credential configuration.
