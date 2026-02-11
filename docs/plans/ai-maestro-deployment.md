# AI Maestro Deployment Plan

**Objective:** Replace pedramamini/Maestro with 23blocks-OS/ai-maestro for Claude Code agent orchestration, observability, and human-in-the-loop control.

**Date:** 2026-02-11
**Status:** Blocked - Image Too Large

## ⚠️ Current Blocker

Docker image is **4.1 GB compressed** (~10GB uncompressed), exceeding Fly.io's 8GB limit.

**Root cause:** AI Maestro's npm dependencies are massive (~800MB+ node_modules, ML models, etc.)

**Resolution options:**
1. Install at runtime instead of build time ← Recommended
2. Upgrade Fly machine size
3. Switch to different orchestration tool

---

## Success Criteria

- [ ] AI Maestro dashboard accessible and secure
- [ ] n8n can trigger Claude Code agents via AI Maestro
- [ ] Web UI provides observability of all running agents
- [ ] Human can intervene/control agents via dashboard
- [ ] All data persists on /data volume
- [ ] Deployment is reproducible via `fly deploy`
- [ ] Authentication/security properly configured

---

## Phase 1: Remove Old Maestro

- [x] Remove Maestro AppImage installation from Dockerfile
- [x] Remove Maestro startup from entrypoint.sh
- [x] Remove Xvfb (only needed for Electron apps)
- [x] Clean up /data/maestro directory reference
- [x] Update fly.toml if needed

---

## Phase 2: Add AI Maestro

### Installation Steps

- [x] Add Node.js 18+ to Dockerfile (already have 22.x ✓)
- [x] Add tmux to Dockerfile (already present ✓)
- [x] Add build-essential to Dockerfile (already have ✓)
- [x] Install AI Maestro via manual git clone method
- [x] Configure AI Maestro to use /data/ai-maestro for persistence

### Files to Modify

- [x] Dockerfile: Add AI Maestro installation
- [x] entrypoint.sh: Start AI Maestro service
- [x] fly.toml: Expose port 23000 for dashboard (with auth note)

---

## Phase 3: Security Configuration

- [ ] Research AI Maestro authentication options
- [ ] Configure authentication for web dashboard
- [ ] Ensure port 23000 is not publicly exposed without auth
- [ ] Use Fly secrets for any credentials
- [ ] Review SECURITY.md from AI Maestro repo

---

## Phase 4: Integration Testing

- [ ] Verify AI Maestro dashboard loads
- [ ] Test Claude Code agent creation
- [ ] Test agent communication (AMP)
- [ ] Verify persistent storage on /data volume
- [ ] Test n8n → AI Maestro integration (CLI/API)

---

## Phase 5: Documentation

- [ ] Document how to access dashboard
- [ ] Document how n8n triggers agents
- [ ] Document authentication setup
- [ ] Update main DEPLOYMENT.md

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Fly.io Machine                      │
│                                                      │
│  ┌──────────┐        ┌──────────────┐               │
│  │   n8n    │───────▶│  AI Maestro  │               │
│  │  :5678   │  API/  │    :23000    │               │
│  └──────────┘  CLI   └──────┬───────┘               │
│                              │                       │
│                              ▼                       │
│                      ┌──────────────┐                │
│                      │ Claude Code  │                │
│                      │   Agents     │                │
│                      └──────────────┘                │
│                                                      │
│  ┌──────────────────────────────────────────────┐   │
│  │    /data/ai-maestro (persistent storage)     │   │
│  │  - Agent configurations                      │   │
│  │  - Conversation history                      │   │
│  │  - CozoDB memory database                    │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
           │
           ▼
    User accesses dashboard
    (authenticated, secure)
```

---

## Technical Details

### AI Maestro Features

- **Dashboard:** Web UI on localhost:23000
- **Agent Management:** Control Claude Code, Aider, Cursor
- **Observability:** Real-time agent monitoring
- **Persistent Memory:** CozoDB embedded database
- **Multi-machine:** Peer mesh network (no central server)
- **AMP:** Agent Messaging Protocol for agent-to-agent communication

### Prerequisites

- Node.js 18+ ✓ (we have 22.x)
- tmux
- build-essential ✓ (already in Dockerfile)
- Claude Code ✓ (already installed and authenticated)

### Installation Method

**Option 1: Automated Script**
```bash
curl -fsSL https://raw.githubusercontent.com/23blocks-OS/ai-maestro/main/scripts/remote-install.sh | sh
```

**Option 2: Manual (More Control)**
```bash
git clone https://github.com/23blocks-OS/ai-maestro.git /opt/ai-maestro
cd /opt/ai-maestro
yarn install
yarn build
# Run as service via ecosystem.config.js
```

---

## Key Differences from Old Maestro

| Feature | Old Maestro (pedramamini) | AI Maestro (23blocks) |
|---------|---------------------------|----------------------|
| Primary UI | Electron desktop app | Web dashboard |
| Agent Support | Generic (any CLI agent) | Claude Code, Aider, Cursor |
| Memory | Session files | CozoDB embedded DB |
| Multi-machine | Via SSH | Peer mesh (AMP) |
| Server Deployment | Unclear/unofficial | Designed for it |
| CLI | maestro-cli.js | Built-in (AMP + CLI scripts) |
| Observability | Basic | Real-time with code graph |

---

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Port 23000 exposed publicly | Configure Fly.io to require auth, or use fly proxy |
| Data loss on redeploy | Mount /data/ai-maestro on persistent volume |
| n8n integration unclear | Test CLI/API during Phase 4, document findings |
| Authentication not set by default | Configure during Phase 3, review SECURITY.md |

---

## References

- [AI Maestro GitHub](https://github.com/23blocks-OS/ai-maestro)
- [Installation Script](https://raw.githubusercontent.com/23blocks-OS/ai-maestro/main/scripts/remote-install.sh)
- [Setup Tutorial](https://github.com/23blocks-OS/ai-maestro/blob/main/docs/SETUP-TUTORIAL.md)
- [Security Policy](https://github.com/23blocks-OS/ai-maestro/blob/main/SECURITY.md)

---

## Progress Log

### 2026-02-11
- Created plan
- Researched AI Maestro installation
- Ready to begin implementation
