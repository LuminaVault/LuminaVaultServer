# Hermes `api_server` Gateway Adapter — Full HTTP Route Surface

Research spike, 2026-07-04. Gates the "BYO-Hermes live proxy" design (LuminaVault server
proxying a user's remote VPS Hermes settings live over HTTP).

## Version examined

- **hermes-agent v0.18.0 (2026.7.1)**, upstream build `19d41744`
- Repo: `https://github.com/NousResearch/hermes-agent.git`, checkout commit
  `6cffc37b5ac4467aa41fbdddbba29e0f04876378` (2026-07-02)
- Source examined on the owner's VPS (`78.46.192.73`) at
  `/usr/local/lib/hermes-agent/gateway/platforms/api_server.py` (4,892 lines)
- **Live-verified** against the running server on VPS loopback `http://127.0.0.1:8642`
  (Bearer `API_SERVER_KEY`, 64-char key). `GET /health` → `{"status":"ok","platform":"hermes-agent","version":"0.18.0"}`.
- All line numbers below refer to `gateway/platforms/api_server.py` at that commit.

**Headline:** the real surface is far larger than the three endpoints documented in
`byo-hermes.md` (`/v1/chat/completions`, `/v1/models`, `/healthz`). There are **35 routes**
across health, discovery, chat, Responses API, structured runs, sessions/history, and
**full cron-job CRUD**. There are **zero** routes for SOUL, memory, config.yaml/providers,
or gateway settings — those remain file-on-disk only.

Note: `/healthz` does **not** exist (it's `/health`); that's a doc bug in `byo-hermes.md`.

## Complete route table

Routes registered in `connect()` at lines 4744–4784. All are unconditional except
`/api/cron/fire` (only when the Chronos cron module imports, line 4777–4778).

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/health` | **none** | Liveness + version (verified unauthenticated 200) |
| GET | `/health/detailed` | Bearer | Extended health incl. process info (line 1356: "Requires the same Bearer auth") |
| GET | `/v1/health` | none | Alias of `/health` (line 4746) |
| GET | `/v1/models` | Bearer | `hermes-agent` pseudo-model + configured `model_routes` aliases (lines 1396–1431; aliases exposed without credentials) |
| GET | `/v1/capabilities` | Bearer | **Self-describing contract**: feature flags + endpoint list (lines 1432–1511) |
| GET | `/v1/skills` | Bearer | Read-only list of installed skills (name/description/category), same data as `/skills list` (lines 1512–1542; verified live) |
| GET | `/v1/toolsets` | Bearer | Toolsets + resolved tool names the api_server agent actually loads (lines 1543+) |
| POST | `/v1/chat/completions` | Bearer | OpenAI-compatible chat, streaming supported; session continuity via `X-Hermes-Session-Id` / `X-Hermes-Session-Key` headers |
| POST | `/v1/responses` | Bearer | OpenAI Responses API compatible (streaming supported) |
| GET | `/v1/responses/{response_id}` | Bearer | Fetch stored response |
| DELETE | `/v1/responses/{response_id}` | Bearer | Delete stored response |
| POST | `/v1/runs` | Bearer | Submit an agent run with structured event streaming |
| GET | `/v1/runs/{run_id}` | Bearer | Run status (line 4143+) |
| GET | `/v1/runs/{run_id}/events` | Bearer | **SSE** structured events (tool progress, approval events) |
| POST | `/v1/runs/{run_id}/approval` | Bearer | Answer a tool-approval request |
| POST | `/v1/runs/{run_id}/stop` | Bearer | Stop a run |
| GET | `/api/sessions` | Bearer | List sessions (SessionDB) |
| POST | `/api/sessions` | Bearer | Create session; body accepts `id`, `model`, **`system_prompt`** (per-session override), `title` (lines 1697–1734) |
| GET | `/api/sessions/{id}` | Bearer | Session metadata |
| PATCH | `/api/sessions/{id}` | Bearer | Update — only `{title, end_reason}` allowed, all else 400 (lines 1746–1770) |
| DELETE | `/api/sessions/{id}` | Bearer | Delete session |
| GET | `/api/sessions/{id}/messages` | Bearer | **Session message history** |
| POST | `/api/sessions/{id}/fork` | Bearer | Fork a session |
| POST | `/api/sessions/{id}/chat` | Bearer | Chat within a session |
| POST | `/api/sessions/{id}/chat/stream` | Bearer | Streaming session chat |
| GET | `/api/jobs` | Bearer | **List cron jobs** (`?include_disabled=true`; lines 3529–3543; verified live — returned real jobs) |
| POST | `/api/jobs` | Bearer | Create cron job: `name`, `schedule`, `prompt`, `deliver`, `skills`, `repeat` (lines 3544+) |
| GET | `/api/jobs/{job_id}` | Bearer | Get job |
| PATCH | `/api/jobs/{job_id}` | Bearer | Update job |
| DELETE | `/api/jobs/{job_id}` | Bearer | Delete job |
| POST | `/api/jobs/{job_id}/pause` | Bearer | Pause job |
| POST | `/api/jobs/{job_id}/resume` | Bearer | Resume job |
| POST | `/api/jobs/{job_id}/run` | Bearer | Run job now |
| POST | `/api/cron/fire` | **NAS-minted JWT** (not API_SERVER_KEY) | Chronos managed-cron fire webhook (NAS → agent); conditional on cron module (lines 4776–4778, 3734) |

### Auth model

- `_check_auth` (lines 1024–1046): constant-time (`hmac.compare_digest`) Bearer check
  against `API_SERVER_KEY` (env or `platforms.api_server.key` in config.yaml, line 828).
  Failure → 401 OpenAI-style error body (verified live: no-auth `GET /v1/models` → 401).
- Startup guard refuses to boot if the key is a placeholder or <16 chars — the code's own
  words: "This endpoint dispatches terminal-capable agent work — a guessable key is remote
  code execution" (lines ~4695–4708).
- Middlewares: CORS (config-gated), body-size limit, security headers (line 4741).
- Defaults: `DEFAULT_PORT = 8642` (line 90), host/port/key from
  `API_SERVER_HOST`/`API_SERVER_PORT`/`API_SERVER_KEY` env or config (lines 823–828).
- `/health` + `/v1/health` are the only unauthenticated routes.

### `/v1/capabilities` — machine-readable contract (use this!)

The server self-describes its surface (lines 1443–1510). Key feature flags from the live
VPS response:

```
chat_completions(+streaming): true    responses_api(+streaming): true
run_submission/status/events_sse/stop/approval: true
session_resources/chat(+streaming)/fork: true
skills_api: true
admin_config_rw: false     jobs_admin: false     memory_write_api: false
audio_api: false           realtime_voice: false
session_continuity_header: X-Hermes-Session-Id
session_key_header: X-Hermes-Session-Key
```

⚠️ Discrepancy: `features.jobs_admin` reports `false` and the `endpoints` map omits
`/api/jobs`, **yet the `/api/jobs` CRUD routes are registered unconditionally and work**
(live `GET /api/jobs` returned the tenant's real cron jobs). Treat the flag as "not part of
the stable plugin contract yet", not as "absent" — feature-detect jobs by probing
`GET /api/jobs` itself.

## Settings domains: HTTP reachability

| Domain | HTTP endpoint? | Evidence |
|---|---|---|
| **SOUL / system prompt** | ❌ No global read/write. ✅ Per-session override only: `system_prompt` accepted on `POST /api/sessions` | Route table 4744–4784 has no soul/prompt route; create_session lines 1721–1725. SOUL.md is file-on-disk |
| **config.yaml / providers / model keys** | ❌ File-on-disk only. Read-only glimpse: `model_routes` aliases surface in `GET /v1/models` (names only, never credentials) | `admin_config_rw: false` (line 1478); `_parse_model_routes` is config-parsing, not an endpoint (lines 1137–1160) |
| **Gateways (Discord/Slack/etc. tokens)** | ❌ File-on-disk only (`.env` / config.yaml + restart) | No route matches; grep for gateway-named handlers in api_server.py: none |
| **Skills** | ⚠️ Read-only: `GET /v1/skills` (list), `GET /v1/toolsets` (resolved tools). No install/enable/disable | Lines 1512–1542; `skills_api: true`; verified live |
| **Memory** | ❌ No CRUD. Only indirect mutation via chat/runs (the agent's own memory tools) | `memory_write_api: false` (line 1480); no memory route registered |
| **Cron / jobs** | ✅ **Full CRUD + pause/resume/run-now** | `/api/jobs*` lines 4766–4773; verified live |
| **Sessions / history** | ✅ Full: list/create/get/patch/delete/**messages**/fork/chat(+stream) | Lines 4752–4760; metadata PATCH limited to `{title, end_reason}` |
| **Chat / inference** | ✅ Three styles: OpenAI chat completions, OpenAI Responses API, native `/v1/runs` with SSE structured events + human-in-the-loop approvals | Lines 4761–4764, 4780–4784 |

## Implications for a LuminaVault BYO-Hermes live proxy

**Design rule: feature-detect with `GET /v1/capabilities` at connect time** and gate every
pane on the flags (plus a `GET /api/jobs` probe for jobs, per the discrepancy above).
Older BYO installs may predate some endpoints; the capabilities endpoint exists precisely
so clients don't assume version parity.

### Proxyable live TODAY (no upstream work)

- **Chat** — already shipped (`/v1/chat/completions`). Upgrade path: `/v1/runs` +
  `/v1/runs/{id}/events` SSE gives tool-progress + approval events, far richer than
  completions streaming; `/v1/runs/{id}/approval` enables a native approval UI.
- **Sessions & history** — LuminaVault can list the user's remote Hermes sessions, render
  message history, rename, fork, delete, and continue them. This is a full remote-session
  browser.
- **Cron jobs** — full remote job management (list/create/edit/pause/resume/run-now/delete).
  The iOS Jobs UI could drive a BYO box's native Hermes cron directly.
- **Skills (read-only)** — live SkillsHub listing of what's actually installed remotely
  (`/v1/skills`), plus effective toolsets (`/v1/toolsets`).
- **Models** — `/v1/models` exposes configured `model_routes` aliases for a remote
  model picker; per-session `model` override on session create.
- **Health/version** — `/health` (keyless) for reachability checks, `/health/detailed`
  for a status pane.
- **System prompt, per-session** — a "custom persona for this chat" feature can ride
  `POST /api/sessions {system_prompt}` today.

### NOT proxyable — needs upstream contribution or graceful degrade

- **SOUL.md global edit** — no endpoint. Degrade: hide/disable the SOUL editor for BYO
  live-proxy connections (or scope it to per-session `system_prompt`). Upstream ask:
  a `/v1/soul` or config-scoped admin route (capabilities already reserves
  `admin_config_rw` for this).
- **config.yaml / provider keys / model routing RW** — `admin_config_rw: false` by design;
  changes require file edit + process restart on the box. Degrade: read-only display of
  models/toolsets; direct users to edit config on their box.
- **Gateway (platform) settings** — same story: env/config files only. The managed-tenant
  flow (write `.env`, restart container) does not translate; a BYO box offers no HTTP hook.
- **Memory CRUD** — `memory_write_api: false`, no routes. Degrade: memory browser stays
  managed-only; on BYO, memory is only reachable conversationally (ask the agent).
- **Skills install/enable/disable** — listing only; mutation is CLI/file-side.

An "agent-mediated" workaround exists in principle (the api_server agent has terminal/file
tools, so a `/v1/runs` prompt could edit SOUL.md or config.yaml on its own host) — but it
is non-deterministic, unauditable, and exactly the RCE-shaped surface the upstream code
warns about. Do not build settings UX on it.

### Explicitly out of scope

**No SSH-based product designs.** SSH was used only as the investigation tool for this
spike. The product proxy speaks HTTP to `api_server` with the user's `API_SERVER_KEY`,
period.

## Security observations from the probe (operational, not design)

1. Upstream code itself warns that a network-accessible api_server with an unsandboxed
   `terminal.backend: local` "runs as the host user with full terminal/file access" and
   references a real **"hermes-0day campaign"** that wrote `~/.hermes/config.yaml` and
   planted persistence (lines ~4800–4825). The LuminaVault BYO onboarding docs should
   push `terminal.backend: docker` + firewall/tunnel, and require strong keys (the ≥16-char
   startup guard is a floor, not a target).
2. ⚠️ **The owner's VPS (78.46.192.73) shows an active cryptominer**:
   `/root/.media/xm/xmrig --url pool.hashvault.pro:443` running as of 2026-07-04, alongside
   an unrecognized `financial-pipeline` script under `/root/.hermes/`. This is consistent
   with the compromise class described above (the box binds api_server on `0.0.0.0:8642`).
   Nothing was modified during this spike (read-only). **Recommend immediate incident
   response on that host** — kill the miner, audit `~/.hermes`, crontabs, systemd units and
   authorized_keys, rotate `API_SERVER_KEY` and any provider keys in config, and prefer
   rebuild over cleanup.
