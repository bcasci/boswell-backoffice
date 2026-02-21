# Claude Flow + boswell-hub Test Readiness on VPS

**Goal:** The `boswell-hub-manager` agent wakes Claude Code with claude-flow MCP tools available, connects to a local PostgreSQL database, and runs the boswell-hub test suite — all surviving `fly deploy`.

**Non-goals:** Changing how boswell-app-manager works.

**Principle:** The VPS is a development workstation. It has the same dependencies the app expects locally (PostgreSQL, Redis, Ruby, master key). The only source file altered on the VPS is `database.yml` — its hardcoded macOS socket path is inherently non-portable. Everything else is environment configuration.

**Precondition (done):** claude-flow installed and committed to boswell-hub repo by user. The `.mcp.json` in boswell-hub uses `npx` to resolve claude-flow at runtime — no global install needed on the VPS.

---

## Deliverables

### 1. Install PostgreSQL and Redis in Docker image

**What:** Add PostgreSQL and Redis to the Dockerfile. Both are real dependencies of boswell-hub — same as a developer's local machine.

**Changes:**
- `Dockerfile` — add `postgresql` and `redis-server` to the `apt-get install` line

**Why Redis?** The `sidekiq.rb` initializer runs on every Rails boot (including test) and calls `Sidekiq::Cron::Job.create`, which connects to Redis. Without Redis, Rails crashes on startup. Locally, developers run Redis. The VPS mirrors that.

---

### 2. Set up PostgreSQL with persistent data (`setup_postgres`)

**What:** Add a `setup_postgres()` function to `entrypoint.sh` that initializes a data directory on the persistent volume and starts the service on every boot.

**Changes to `entrypoint.sh`:**
- Add `setup_postgres()` function:
  - Creates `/data/postgres` if not exists, owned by `postgres` user
  - Initializes cluster with `initdb` on first boot (idempotent: skips if PG_VERSION file exists)
  - Starts PostgreSQL with data dir `/data/postgres`
  - Creates `agent` superuser role if not exists
  - Runs before `bootstrap_ruby_for_repos` in the `main()` sequence

**Data persistence:** `/data/postgres` lives on the 10GB persistent volume. Databases, roles, and data survive deploys. Only the PostgreSQL binaries are reinstalled from the image.

**Verification:**
- [ ] `fly ssh console -C "pg_isready"` returns "accepting connections"
- [ ] `fly ssh console -C "su - agent -c 'psql -l'"` lists databases
- [ ] After a `fly deploy`, PostgreSQL starts automatically and databases are intact

---

### 3. Start Redis in entrypoint

**What:** Add `start_redis()` to `entrypoint.sh` that starts Redis on every boot. No persistence needed — Redis is only used for Sidekiq job definitions, which are recreated from the initializer on each Rails boot.

**Changes to `entrypoint.sh`:**
- Add `start_redis()` function: starts `redis-server --daemonize yes`
- Wire into `main()` after `setup_postgres()`

**Verification:**
- [ ] `fly ssh console -C "redis-cli ping"` returns "PONG"

---

### 4. Patch database.yml socket path for VPS

**What:** boswell-hub's `database.yml` (dev and test) uses `host: /Users/brandoncasci/.asdf/installs/postgres/12.1/sockets` — the developer's local macOS socket path. On the VPS, PostgreSQL creates its socket at `/var/run/postgresql`. This is the one source file that needs patching — a hardcoded macOS path is inherently non-portable.

**Changes to `entrypoint.sh`:**
- In `bootstrap_hub_tests()`, use `sed` to replace the macOS socket path with `/var/run/postgresql` in `config/database.yml`
- Guard: only patch if the macOS path is still present (idempotent — skips if already patched)

**Verification:**
- [ ] `fly ssh console -C "su - agent -c 'cd /data/agents/boswell-hub-manager/repo && grep var/run/postgresql config/database.yml'"` shows patched lines
- [ ] `fly ssh console -C "su - agent -c 'psql -h /var/run/postgresql -l'"` lists databases

---

### 5. Deploy BOSWELL_HUB_MASTER_KEY as a Fly secret

**What:** Set the boswell-hub master key as a **qualified** Fly secret (`BOSWELL_HUB_MASTER_KEY`, not generic `RAILS_MASTER_KEY`). The entrypoint reads it during boot and writes it to `config/master.key` inside the boswell-hub repo clone. The dispatcher also writes it into each issue clone. Rails finds the file and decrypts `credentials.yml.enc` normally.

**IMPORTANT:** Do NOT export the key to `.zshenv` or use the generic `RAILS_MASTER_KEY` name. The env var would apply to ALL Rails apps. boswell-hub and boswell-app have different master keys. Using a qualified secret name + per-repo `config/master.key` file isolates each app's credentials.

**Changes:**
- One-time: `fly secrets set BOSWELL_HUB_MASTER_KEY=<key> -a backoffice-automation`
- `entrypoint.sh` — in `bootstrap_hub_tests()`, write `$BOSWELL_HUB_MASTER_KEY` to `config/master.key` in the hub repo (idempotent: skips if file exists)
- `agent-dispatcher.json` — after issue clone for boswell-hub, write `$BOSWELL_HUB_MASTER_KEY` to the clone's `config/master.key`, enable dev caching, and patch `database.yml`

**Why:** The mailerlite and auth0 initializers read credentials via `Rails.application.credentials`. With the master key file present, credentials decrypt normally — no initializer patches needed.

**Verification:**
- [x] `fly ssh console -C "su - agent -c 'cd /data/agents/boswell-hub-manager/repo && bundle exec rails runner \"puts Rails.application.credentials.dig(:development, :auth0_client_secret).present?\"'"` returns `true`

---

### 6. Bootstrap boswell-hub databases in entrypoint

**What:** Add a `bootstrap_hub_tests()` function to `entrypoint.sh` that runs `db:prepare` for both development and test environments. Runs as a background task after Ruby bootstrap completes (depends on Ruby + bundle being ready). No source files are modified.

**Changes to `entrypoint.sh`:**
- Add `bootstrap_hub_tests()` function:
  - Write `config/master.key` from Fly secret (per-repo, not global env)
  - Create `tmp/caching-dev.txt` (enables dev caching — required by development.rb for auth0 session store)
  - Patch `database.yml` socket path (macOS → Linux)
  - `bundle exec rails db:prepare` — development database (Rails default)
  - `RAILS_ENV=test bundle exec rails db:prepare` — test database
- Wire into `main()` after `bootstrap_ruby_for_repos` (chained in the same background `&` block)

**Idempotency:** `db:prepare` is a no-op if the database and schema are current. Safe on every boot.

**Verification:**
- [ ] `fly ssh console -C "su - agent -c 'cd /data/agents/boswell-hub-manager/repo && RAILS_ENV=test bundle exec rails runner \"puts ActiveRecord::Base.connection.tables.count\"'"` returns a number > 0

---

### 7. Upsize VM if needed

**What:** Evaluate whether shared-cpu-2x/4GB is sufficient for running n8n + AI Maestro + Caddy + PostgreSQL + Redis + Claude Code + Ruby test suite concurrently. If not, upsize in `fly.toml`.

**Decision:** Keep shared-cpu-2x/4GB for now. Upsize to shared-cpu-4x/8GB only if test runs OOM. The `fly.toml` change is a one-liner if needed.

**Verification:**
- [ ] After deploy, `fly status -a backoffice-automation` shows correct VM size
- [ ] During test runs, no OOM kills in `fly logs`

---

### 8. Verify boswell-app-manager is unaffected

**What:** After deploy, confirm the boswell-app-manager agent works exactly as before. The only changes that could affect it are Dockerfile additions (PostgreSQL, Redis) which are additive.

**Verification:**
- [ ] `fly ssh console -C "su - agent -c 'cd /data/agents/boswell-app-manager/repo && bundle check'"` succeeds
- [ ] Wake boswell-app-manager via AI Maestro API — agent starts without errors
- [ ] boswell-app test suite still passes: `RAILS_ENV=test bundle exec rails test` (1029 tests, 0 errors expected)

---

### 9. End-to-end: boswell-hub-manager runs tests with claude-flow

**What:** Wake the boswell-hub-manager agent and verify it can run the test suite in a Claude Code session with claude-flow MCP available.

**Preconditions:** Deliverables 1-6 deployed, VPS clone has pulled latest boswell-hub with claude-flow config.

**Verification:**
- [ ] Wake agent: `curl -s -X POST http://localhost:23001/api/agents/76d4513d-7f77-478a-bbf4-50a89fd69a75/wake`
- [ ] Claude Code starts and claude-flow MCP server connects (visible in Claude startup output)
- [ ] `RAILS_ENV=test bundle exec rails test` runs — expect 875 runs, ~100 Shakapacker errors (no webpack on VPS), core tests pass
- [ ] Agent can be hibernated cleanly after test run

---

## Implementation Order

```
1. Set BOSWELL_HUB_MASTER_KEY Fly secret                                ← no deploy needed
2. Dockerfile changes (PostgreSQL + Redis)                              ← no deploy yet
3. entrypoint.sh changes (setup_postgres + start_redis + database.yml   ← no deploy yet
   patch + bootstrap_hub_tests with per-repo master.key)
4. agent-dispatcher.json (write master.key + caching + db.yml into      ← no deploy yet
   boswell-hub issue clones)
5. fly deploy                                                           ← single deploy
6. Update dispatcher in n8n DB + restart n8n                            ← DB update
7. Unset old RAILS_MASTER_KEY secret                                    ← cleanup
8. Verify all services running
9. Verify credentials decrypt
10. Verify boswell-app unaffected
11. Verify end-to-end (wake agent, run tests)
```

---

## Files Modified

| File | Change |
|---|---|
| `Dockerfile` | Add `postgresql` and `redis-server` to apt |
| `entrypoint.sh` | Add `setup_postgres()`, `start_redis()`, add `bootstrap_hub_tests()` (per-repo master.key from `BOSWELL_HUB_MASTER_KEY`, patches database.yml, db:prepare), wire into `main()` |
| `workflows/agent-dispatcher.json` | Write `config/master.key`, `tmp/caching-dev.txt`, patch `database.yml` in boswell-hub issue clones |
| `fly.toml` | No change (4GB sufficient; upsize later if needed) |
| Fly secret | `BOSWELL_HUB_MASTER_KEY` set via `fly secrets set` (replaces generic `RAILS_MASTER_KEY`) |

**boswell-hub source files NOT modified:** sidekiq.rb, mailerlite.rb, auth0.rb, or any other file. The only VPS-side alteration is `database.yml` (macOS socket path → Linux socket path). Everything else is environment configuration (services, secrets, env vars).

---

## Known Limitations

- **Shakapacker tests (~100):** Will fail without `yarn install` + webpack build on VPS. This is pre-existing and out of scope — core model/service/job tests pass.
- **First boot after deploy:** `bootstrap_hub_tests()` takes 1-2 minutes (db:prepare). Subsequent boots are near-instant (idempotent checks skip).
- **claude-flow first run:** npx downloads `@claude-flow/cli` on first MCP server start (~15s). Subsequent runs use npx cache.
- **database.yml patch:** The `sed` replaces the macOS socket path with `/var/run/postgresql`. If the macOS path changes in the committed file, the sed pattern in `entrypoint.sh` must be updated to match. The patch is guarded and idempotent.

---

## Follow-up Improvements (separate phase)

See `docs/plans/backoffice-improvements-backlog.md` for items identified during this work that are too broad for this scope.
