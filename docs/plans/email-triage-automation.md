# Email Triage Automation - Implementation Plan

## Goal

Automate email classification and responses for business Gmail (brandon@boswell.io) using n8n, Claude, and Gmail API.

## Success Criteria

- [ ] Emails automatically classified by type/urgency
- [ ] Common questions auto-responded with FAQ knowledge
- [ ] Cold sales deleted/ignored automatically
- [ ] Investor/partnership emails escalated to Slack
- [ ] Bug reports trigger GitHub issue creation (or ask for more info)
- [ ] System runs unattended on Fly.io
- [ ] Visible audit trail in Slack + n8n execution history

---

## Phase 0: Gmail API Setup ✅ COMPLETED

### Person Tasks

- [x] Create Google Cloud OAuth client for Gmail API
- [x] Configure OAuth consent screen
- [x] Add authorized redirect URI for n8n
- [x] Authenticate Gmail account in n8n

### AI Tasks

- [x] Add N8N_EDITOR_BASE_URL to deployment config
- [x] Deploy updated configuration to Fly.io
- [x] Verify OAuth callback URL works correctly

**Status:** OAuth credentials created and working. Reusable across all workflows.

---

## Phase 1: FAQ Seeding (Inbox Analysis)

**Goal:** Analyze existing inbox to extract common customer questions and seed initial FAQ.

### Person Tasks

- [ ] Define search criteria for customer emails (e.g., specific domains, date range)
- [ ] Review generated FAQ for accuracy
- [ ] Edit/organize FAQ as needed

### AI Tasks

- [ ] Create n8n workflow: "FAQ Seeder"
  - Gmail node: "Get many messages" with search query
  - Loop through messages (limit 100-500)
  - Send batches to Claude for pattern analysis
  - Aggregate common Q&A pairs
  - Write to `/data/customer-faq.md`
- [ ] Test workflow and validate output
- [ ] Document how to re-run for FAQ updates

**Output:** `/data/customer-faq.md` - structured FAQ file for reference

---

## Phase 2: Gmail Trigger & Classification

**Goal:** Set up main triage workflow to classify incoming emails.

### Person Tasks

- [ ] Confirm email categories:
  - Cold sales (auto-delete)
  - Investor/partnership inquiries (escalate to Slack)
  - Customer questions (check FAQ, auto-respond or escalate)
  - Bug reports (create GitHub issue or ask for details)
- [ ] Provide example emails for each category (if needed)
- [ ] Set polling interval (recommended: 5-10 min)

### AI Tasks

- [ ] Create n8n workflow: "Email Triage"
- [ ] Add Gmail Trigger node
  - Configure with OAuth credential
  - Set polling mode (5-10 min)
  - Event: Message Received
- [ ] Add Claude node for classification
  - Prompt: Classify email into categories
  - Input: email subject, from, body
  - Output: category + confidence + reasoning
- [ ] Add Switch/IF node for routing by category
- [ ] Test classification with sample emails

---

## Phase 3: Auto-Response Logic

**Goal:** Respond to customer questions automatically when answer is in FAQ.

### Person Tasks

- [ ] Review response tone/style (polite, concise, sounds like you)
- [ ] Approve sample auto-responses
- [ ] Define when to escalate vs auto-respond

### AI Tasks

- [ ] Add FAQ reading logic
  - Read `/data/customer-faq.md` into context
- [ ] Add Claude node for response generation
  - Check if question is answerable from FAQ
  - Generate response in user's voice
  - Include disclaimer if uncertain
- [ ] Add Gmail "Reply to message" node
- [ ] Add "confidence check" - only auto-respond if high confidence
- [ ] Test with real customer questions

**Rules:**

- Auto-respond if FAQ has clear answer AND high confidence
- Escalate to Slack if uncertain or FAQ doesn't cover it

---

## Phase 4: Actions by Category

**Goal:** Handle each email type appropriately.

### Person Tasks

- [ ] Decide: delete cold sales or move to trash? (safer: trash)
- [ ] Confirm GitHub issue template for bug reports
- [ ] Review when to ask customers for more info vs creating issue directly

### AI Tasks

**Cold Sales:**

- [ ] Move to trash (reversible)
- [ ] Log to n8n execution history

**Investor/Partnership:**

- [ ] Send to Slack (#boswell-email-alerts)
- [ ] Include: from, subject, preview, link to Gmail

**Customer Questions (if not auto-responded):**

- [ ] Send to Slack for manual response
- [ ] Tag as "needs-response"

**Bug Reports:**

- [ ] Analyze if enough info provided (error message, steps, etc.)
- [ ] If sufficient: create GitHub issue with `gh` CLI
- [ ] If insufficient: reply asking for details (error msg, screenshot, repro steps)
- [ ] Send Slack notification with GitHub issue link

---

## Phase 5: Slack Notifications & Audit Trail

**Goal:** Get notified of emails that need attention.

### Person Tasks

- [ ] Create Slack channel: `#boswell-email-alerts`
- [ ] Generate Slack incoming webhook URL
- [ ] Test notifications work on mobile

### AI Tasks

- [ ] Add Slack webhook to n8n
- [ ] Configure message format:
  ```
  🔔 [Category] - Needs Review
  From: sender@example.com
  Subject: Email subject
  Preview: First 100 chars...
  [View in Gmail] [Mark Handled]
  ```
- [ ] Add Slack notifications for:
  - Investor emails (always)
  - Customer questions Claude can't answer
  - Bug reports created
  - Classification failures
- [ ] Test notifications end-to-end

**Logging:** Use n8n's built-in execution history (already persistent on `/data`)

---

## Phase 6: Production & Monitoring

### Person Tasks

- [ ] Activate workflow in n8n
- [ ] Monitor Slack alerts for first 48 hours
- [ ] Check n8n execution history daily
- [ ] Adjust categories/responses based on real patterns
- [ ] Add new Q&A to FAQ as needed

### AI Tasks

- [ ] Verify workflow is active and polling
- [ ] Verify credentials persist across container restarts
- [ ] Add error handling (retry logic, fallback to Slack on failure)
- [ ] Document workflow for maintenance
- [ ] Create runbook for common issues

---

## Future Enhancements

### Person Tasks

- [ ] Consider Gmail labels for visual organization (requires labels API scope)
- [ ] Decide if RAG needed for more complex product questions

### AI Tasks

- [ ] Schedule FAQ refresh workflow (weekly/monthly)
- [ ] Add learning loop: track which auto-responses get follow-ups
- [ ] Optimize polling interval based on volume
- [ ] Add sentiment analysis for urgent/angry emails

---

## Known Decisions

**Technical:**

- ✅ Gmail API with OAuth (not IMAP - required for Workspace)
- ✅ Claude for classification and response generation
- ✅ Slack for notifications (#boswell-email-alerts)
- ✅ n8n execution history for audit trail
- ✅ FAQ stored as markdown on `/data` volume
- ✅ Polling interval: 5-10 minutes (not real-time)

**Email Handling:**

- Cold sales → Move to trash (not delete - reversible)
- Investors → Always escalate to Slack
- Customer questions → Auto-respond if FAQ covers it, else Slack
- Bug reports → Create GitHub issue (or ask for details first)

**Response Style:**

- Polite, concise, not verbose
- Sounds like Brandon
- Include disclaimer when uncertain
