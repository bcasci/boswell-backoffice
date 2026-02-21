# End-to-End Test Plan

**Date:** 2026-02-21
**Status:** COMPLETE
**Goal:** Verify full pipeline works for both repos: issue creation -> spec -> implement -> commit -> push -> PR

---

## Known Issue: Agent Premature Idle

User reports: Claude Code goes fully idle (shows prompt `>`) mid-task. Sending "continue" nudges it along. Root cause: no ralph-wiggum wrapping (chained slash commands don't work per MEMORY.md), so nothing prevents Claude from stopping early.

**Fix applied (dispatcher v4.1):** Automatic nudge mechanism. When agent goes idle, dispatcher checks job type max_nudges (implement=5, spec=0, comment=1). Sends "continue" nudges via tmux before marking job complete. Also improved idle detection to prevent false positives from queued messages.

---

## Phase 1: System Health Verification - PASS

- [x] 1.1 Machine running (state: started, region: ewr)
- [x] 1.2 All 3 workflows active (hub intake, app intake, dispatcher)
- [x] 1.3 Webhooks registered on both repos
- [x] 1.4 Both agent tmux sessions running
- [x] 1.5 Queues empty, no stale .active files
- [x] 1.6 Server dispatcher matches local copy (v3)

## Phase 2: Dispatcher Nudge Enhancement - DONE

- [x] 2.1 Designed nudge logic (max_nudges per job type, no min_dur gate)
- [x] 2.2 Added `nudge_count` to .active file schema
- [x] 2.3 Modified completion check with nudge logic
- [x] 2.4 Deployed dispatcher v4.1 to server (3 iterations: v4 -> fix nudge logic -> fix idle detection)
- [x] 2.5 Verified dispatcher runs clean

**Iteration history:**
1. v4: Added nudge with min_dur gate — spec nudge caused /dev-start on master (side effect)
2. v4 fix: Set spec max_nudges=0, removed min_dur from nudge decision
3. v4.1: Fixed check_idle() to analyze last 3 lines instead of grepping entire buffer

## Phase 3: boswell-hub End-to-End Test - PASS

### 3.1 Spec Test - PASS
- [x] Created issue #1117: "Add health check endpoint returning JSON status"
- [x] Added `agent-spec` label
- [x] Pipeline: webhook -> intake queued job -> dispatcher picked up -> agent woke -> agent wrote spec
- [x] Spec written to issue body (excellent quality: outcomes, constraints, acceptance criteria)
- [x] Dispatcher marked complete (3 min, 1 nudge — nudge was unnecessary, fixed in v4.1)

### 3.2 Implement Test - PASS
- [x] Added `agent-implement` label
- [x] Workspace created at `/data/agents/boswell-hub-manager/issues/issue-1117/`
- [x] Branch `issue/1117` created correctly
- [x] Agent: read issue -> explored codebase -> wrote tests (RED) -> wrote controller + route (GREEN) -> committed -> pushed -> PR #1118
- [x] PR #1118 created with proper summary, linked to issue #1117
- [x] Dispatcher posted start + complete comments (9 min, 3 nudges)
- [x] 3 nudges needed: after code write, after test run, after thinking about Shakapacker errors

## Phase 4: boswell-app End-to-End Test - PASS

### 4.1 Spec Test - PARTIAL PASS
- [x] Created issue #261: "Add application version endpoint"
- [x] Added `agent-spec` label
- [x] Pipeline worked correctly (webhook -> intake -> queue -> dispatch -> agent)
- [x] Agent ran `/github:update-issue` skill, generated comprehensive spec
- [ ] **BUG:** Spec output to terminal but NOT written to GitHub issue body (skill issue, not pipeline)
- [x] Dispatcher marked complete (2 min, 0 nudges)

### 4.2 Implement Test - PASS
- [x] Added `agent-implement` label
- [x] Workspace created, branch `issue/261`, guardrails injected
- [x] Agent: analyst subagent (1m) -> phase-implementor subagent -> wrote controller + tests + route -> committed -> pushed -> PR #262
- [x] PR #262 created with proper summary
- [x] Dispatcher posted start + complete comments (7 min, 5 nudges)
- [x] **Note:** 5 nudges piled up during a long thinking state — caused by idle detection false positive (fixed in v4.1)

## Phase 5: Improvements Backlog Update - DONE

- [x] Added items 8-12 to backlog:
  - #8: Agent premature idle (with fix details and test results)
  - #9: Idle detection false positives (with fix details)
  - #10: boswell-app `/github:update-issue` skill bug
  - #11: Evaluate `claude -p` headless mode
  - #12: Workflow seeding only works on first boot
- [x] Updated item #7 (ghost commands) with e2e test evidence

## Phase 6: Celebratory Report - See below
