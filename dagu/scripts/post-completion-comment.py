#!/usr/bin/env python3
"""Update the GitHub comment to show completion status.

Reads /tmp/dagu-comment-id and /tmp/dagu-start-time from post-start-comment.

Env vars: AGENT_NAME, ISSUE_NUM, REPO, ACTION, GH_TOKEN
"""
import json, urllib.request, os
from datetime import datetime, timezone

comment_id = open('/tmp/dagu-comment-id').read().strip()
if not comment_id:
    print("No comment ID — skipping completion update")
    exit(0)

start_str = open('/tmp/dagu-start-time').read().strip()
start = datetime.fromisoformat(start_str)
now = datetime.now(timezone.utc)
dur = int((now - start).total_seconds() / 60)

agent = os.environ.get('AGENT_NAME', 'unknown')
issue = os.environ.get('ISSUE_NUM', '?')
repo = os.environ.get('REPO', '')
action = os.environ.get('ACTION', '')

body = "\n".join([
    f"\U0001f916 **{agent}** finished working on this issue.",
    "",
    f"**Task:** {action} \u00b7 **Issue:** #{issue}",
    f"**Started:** {start.strftime('%Y-%m-%d %H:%M UTC')}",
    f"**Completed:** {now.strftime('%Y-%m-%d %H:%M UTC')} \u00b7 Duration: {dur}m",
    "**Status:** \u2705 Complete",
])

data = json.dumps({"body": body}).encode()
req = urllib.request.Request(
    f"https://api.github.com/repos/{repo}/issues/comments/{comment_id}",
    data=data, method='PATCH',
    headers={
        'Authorization': f"token {os.environ.get('GH_TOKEN', '')}",
        'Accept': 'application/vnd.github+json',
        'Content-Type': 'application/json',
    }
)
try:
    urllib.request.urlopen(req)
    print(f"COMPLETE: {agent} #{issue} ({action}) - {dur}m")
except Exception as e:
    print(f"WARNING: failed to update completion comment: {e}")
