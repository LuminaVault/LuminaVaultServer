# Plan — Hermes Cron Bridge (list → create from chat)

## Context

Users want **TUI parity on iOS for cron**: *see* the cron jobs their Hermes runs
and *create* them by chatting, exactly like `hermes cron` in the terminal. Live
example (the test VPS): `twice-daily-news-digest` (Discord/Telegram, `0 9,17`),
`daily-ios-swift-job-scraper` (Telegram, `scrape_ios_jobs.py`), … ~many in
`~/.hermes/cron/jobs.json`.

These are **Hermes-native** jobs (managed via `hermes cron` — `list / create /
edit / pause / resume / run / remove`). They are **not** the same as LuminaVault's
own `CronScheduler` (`Sources/App/Skills/CronScheduler.swift`, vault-cron skills
filed into Spaces) and they are **not** reachable over the OpenAI `/v1` API. So we
need a **bridge** to Hermes's cron management.

Goal: a Jobs surface that **lists** the connected Hermes's cron jobs and lets the
user **create** one from natural-language chat — managed first, BYO next.

## Hermes cron CLI (the contract to wrap)

```
hermes cron list
hermes cron create <schedule> [prompt] --name --deliver <origin|telegram|discord|signal|platform:chat>
                    --repeat --skill <s> --script <path> --no-agent --workdir --profile
hermes cron edit | pause | resume | run | remove <id>
```
`schedule` accepts `30m`, `every 2h`, or cron (`0 9 * * *`). Job = prompt-agent or
`--no-agent` script.

## Transport (the key decision)

| Hermes location | How LuminaVault reaches `hermes cron` |
|---|---|
| **Managed** (LuminaVault per-tenant container) | **`docker exec` the container** — reuse the existing pattern in `Plugins/HermesHubSkillsService.swift` + `Models/HermesTenantContainer.swift` (already execs `hermes skills` into the tenant container). **MVP target.** |
| **BYO** (user's own/remote Hermes, e.g. the VPS) | **CONFIRMED:** the dashboard (`:9119`, externally reachable) serves **`GET /api/cron/jobs` → 200** with the full jobs JSON (and `POST` to create). Auth = `Authorization: Bearer <dashboard __HERMES_SESSION_TOKEN__>` (embedded in the dashboard HTML). `/v1` (`:8642`) is chat-only — not this. ⚠️ Security: the dashboard is the **full admin UI**, broader than `/v1`; exposing it + handing LuminaVault a dashboard token is heavier than the api_server. Implementation: a `BYODashboardCronClient` + a stored dashboard URL+token (separate from the api_server BYO config). |

**All cases are in scope** (managed container, BYO remote, standalone/system-wide
— standalone is the BYO transport since there's no container to exec). Build
order: **managed/exec first** (achievable now, testable on the local
`hermes-agent`), then the **BYO transport** right after.

**Read source:** `hermes cron list` has no `--json`; the source of truth is
`$HERMES_HOME/cron/jobs.json` = `{ jobs: [ {id, name, prompt, schedule, deliver,
skills, script, no_agent, workdir, last_run, status} ], updated_at }`. Managed:
`cat` it via exec. BYO: the dashboard API (`:9119`) serves the same data — or, if
it exposes a cron write endpoint, use that for create.

## Backend

1. **`CronBridgeService`** (new, `Sources/App/Skills/`):
   - `list(tenantID) -> [HermesCronJob]` — exec `hermes cron list --json` (or
     parse the table) in the tenant container → structured DTOs.
   - `create(tenantID, spec) -> HermesCronJob` — exec `hermes cron create …`
     mapping spec fields to flags; return the created job.
   - `pause/resume/remove(tenantID, id)` — exec the matching subcommand.
   - Reuse the container handle/exec helper from `HermesHubSkillsService`
     (factor the `docker exec` runner into a small shared `HermesContainerExec`).
2. **NL → cron spec:** reuse **`JobIntentClassifier`** + `JobAuthoring`
   (`Sources/App/Skills/`) — they already turn a chat turn into a structured job
   intent. Extend the output to the `hermes cron create` field set (schedule,
   prompt, name, deliver, skill/script). The LLM call goes through `routedTransport`.
3. **`CronBridgeController`** — `/v1/me/hermes/cron`:
   `GET` (list), `POST` (create from a structured spec), `POST /preview`
   (NL → spec, no write), `POST /:id/pause|resume`, `DELETE /:id`. JWT-gated;
   gated on the tenant having a managed container (or BYO mgmt API in Phase 2).

## iOS

- Extend **`Features/Jobs/JobsListView.swift`** with a **"Hermes Cron"** section
  (name · schedule · deliver target · last-run · status), separate from
  LuminaVault's native Jobs. `JobDetailView` shows the job; pause/resume/delete.
- **Create from chat:** reuse the **`JobProposalCard`** flow — chat "make a daily
  9am stock digest to Telegram" → server `/preview` returns the parsed cron spec
  → card confirms → `POST` creates it on Hermes. (Same UX shape as the existing
  chat→Job proposal.)
- Client + endpoints; Shared DTOs `HermesCronJob`, `HermesCronCreateRequest`,
  `HermesCronPreviewResponse` (Shared bump).

## Phasing

- **Phase 1 (MVP): LIST (read-only)** — managed exec → list Hermes cron in the
  app. Instant "what's running" visibility. Lowest risk.
- **Phase 2: CREATE from chat** — NL→spec (`/preview`) + create (managed exec).
- **Phase 3: edit/pause/resume/remove** + **BYO transport** (dashboard `:9119`
  cron API). 
- **Defer:** skills install/list parity, per-job run history, delivery-target
  picker UI beyond the common set.

## Reuse map
- Exec: `Plugins/HermesHubSkillsService.swift`, `Models/HermesTenantContainer.swift`.
- NL→job: `Skills/JobIntentClassifier.swift`, `Skills/JobAuthoring.swift`,
  `Skills/JobsController.swift`.
- iOS: `Features/Jobs/JobsListView.swift`, `JobDetailView.swift`,
  `Chat/Components/JobProposalCard.swift`.
- LLM: `routedTransport`. (Do **not** reuse `CronScheduler` — that's LuminaVault's
  separate native scheduler, not Hermes cron.)

## Verification
1. Managed tenant: `GET /v1/me/hermes/cron` returns the container's
   `hermes cron list` jobs.
2. Chat "remind me daily at 9 to review my portfolio, deliver to Telegram" →
   `/preview` returns `{schedule:"0 9 * * *", deliver:"telegram", …}` → confirm →
   the job appears in `hermes cron list` inside the container.
3. Pause/resume/delete reflect in `hermes cron list`.
4. (Phase 3) Same against the BYO VPS via the dashboard cron API.
