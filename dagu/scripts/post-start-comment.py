#!/usr/bin/env python3
"""Post a GitHub comment when an agent starts working on an issue.

Writes /tmp/dagu-comment-id and /tmp/dagu-start-time for later steps.

Env vars: AGENT_NAME, ISSUE_NUM, REPO, ACTION, GH_TOKEN
"""
import json, urllib.request, os
from datetime import datetime, timezone

now = datetime.now(timezone.utc)
agent = os.environ.get('AGENT_NAME', 'unknown')
issue = os.environ.get('ISSUE_NUM', '0')
repo = os.environ.get('REPO', '')
action = os.environ.get('ACTION', '')

body = "\n".join([
    f"\U0001f916 **{agent}** is working on this issue.",
    "",
    f"**Task:** {action} \u00b7 **Issue:** #{issue}",
    f"**Started:** {now.strftime('%Y-%m-%d %H:%M UTC')}",
    "**Status:** \u23f3 In progress...",
])

data = json.dumps({"body": body}).encode()
req = urllib.request.Request(
    f"https://api.github.com/repos/{repo}/issues/{issue}/comments",
    data=data, method='POST',
    headers={
        'Authorization': f"token {os.environ.get('GH_TOKEN', '')}",
        'Accept': 'application/vnd.github+json',
        'Content-Type': 'application/json',
    }
)
try:
    resp = urllib.request.urlopen(req)
    comment = json.loads(resp.read())
    with open('/tmp/dagu-comment-id', 'w') as f:
        f.write(str(comment['id']))
    with open('/tmp/dagu-start-time', 'w') as f:
        f.write(now.isoformat())
    print(f"STARTED: {agent} #{issue} ({action}) - comment {comment['id']}")
except Exception as e:
    print(f"WARNING: failed to post start comment: {e}")
    # Write dummy files so later steps don't fail
    with open('/tmp/dagu-comment-id', 'w') as f:
        f.write('')
    with open('/tmp/dagu-start-time', 'w') as f:
        f.write(datetime.now(timezone.utc).isoformat())
