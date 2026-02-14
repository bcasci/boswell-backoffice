#!/bin/bash
# build-faq.sh — Analyze customer emails and build FAQ document
#
# Usage: build-faq.sh <emails.json> [batch_size]
#
# Reads a JSON array of email objects from <emails.json>, splits them into
# batches, and invokes Claude on each batch to incrementally build
# /data/customer-faq.md.
#
# Expected JSON format: [{"snippet":"...","subject":"...","from":"..."}, ...]

set -euo pipefail

EMAILS_FILE="${1:?Usage: build-faq.sh <emails.json> [batch_size]}"
BATCH_SIZE="${2:-15}"
FAQ_FILE="/data/customer-faq.md"

if [ ! -f "$EMAILS_FILE" ]; then
  echo "ERROR: $EMAILS_FILE not found" >&2
  exit 1
fi

TOTAL=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$EMAILS_FILE','utf8')).length)")
BATCHES=$(( (TOTAL + BATCH_SIZE - 1) / BATCH_SIZE ))

echo "Processing $TOTAL emails in $BATCHES batches of $BATCH_SIZE"

for (( i=0; i<BATCHES; i++ )); do
  OFFSET=$(( i * BATCH_SIZE ))
  BATCH_NUM=$(( i + 1 ))

  echo "--- Batch $BATCH_NUM/$BATCHES (offset $OFFSET) ---"

  # Extract this batch's snippets into a prompt
  PROMPT=$(node -e "
    const emails = JSON.parse(require('fs').readFileSync('$EMAILS_FILE','utf8'));
    const batch = emails.slice($OFFSET, $OFFSET + $BATCH_SIZE);
    const snippets = batch.map((e, i) => [
      (i+1) + '. FROM: ' + (e.from || e.sender || 'unknown'),
      '   SUBJECT: ' + (e.subject || 'no subject'),
      '   SNIPPET: ' + (e.snippet || '')
    ].join('\n')).join('\n\n');

    const prompt = 'Analyze these ' + batch.length + ' customer email snippets (batch $BATCH_NUM of $BATCHES). ' +
      'Extract common questions and issues, then append unique FAQ entries to $FAQ_FILE ' +
      '(create the file if it does not exist).\n\n' +
      'Email snippets:\n' + snippets + '\n\n' +
      'Instructions:\n' +
      '- If $FAQ_FILE exists, read it first to avoid duplicates\n' +
      '- Append new unique Q&A entries\n' +
      '- Format: ## Category then **Q:** Question? then **A:** Answer\n' +
      '- Only add questions that appear in multiple emails or are clearly important\n' +
      '- Respond with ONLY a short summary line: Added N entries to FAQ (or No new entries)';

    process.stdout.write(prompt);
  ")

  # Write prompt to temp file to avoid shell quoting issues
  PROMPT_FILE=$(mktemp /tmp/faq-prompt-XXXXXX.txt)
  echo "$PROMPT" > "$PROMPT_FILE"

  # Run Claude
  RESULT=$(claude -p --dangerously-skip-permissions < "$PROMPT_FILE" 2>&1) || {
    echo "  ERROR on batch $BATCH_NUM: $RESULT" >&2
    rm -f "$PROMPT_FILE"
    continue
  }

  rm -f "$PROMPT_FILE"
  echo "  $RESULT"
done

echo "--- Done. FAQ at $FAQ_FILE ---"
if [ -f "$FAQ_FILE" ]; then
  echo "FAQ size: $(wc -c < "$FAQ_FILE") bytes, $(grep -c '^\*\*Q:\*\*' "$FAQ_FILE" 2>/dev/null || echo 0) questions"
fi
