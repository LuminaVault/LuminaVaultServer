# Handoff — Hermes Phase 1: Act from your pocket (runs + approvals)

Branch: `feat/hermes-p1-runs` (server), `feat/hermes-p1-dtos` (Shared).
Nothing is pushed or tagged. Six commits, each building and tested.

Value: start an agent run on your own Hermes from the app, watch it live,
approve or deny a tool call from a push notification, stop it.

## What shipped (server)

| Area | Files |
| --- | --- |
| Gateway client | `Sources/App/Hermes/Runs/HermesRunsClient.swift`, `HermesRunsHTTP.swift`, `HermesRunEvent.swift`, `SSEFrameParser.swift` |
| Persistence | `Sources/App/Models/HermesRun.swift`, `Sources/App/Migrations/M117…M119` |
| Service | `HermesRunStore.swift`, `HermesRunWatcher.swift`, `HermesRunPushNotifier.swift`, `HermesRunsService.swift` |
| HTTP | `HermesRunsController.swift`, `Sources/App/HTTP/SSEResponse.swift` (new `EncodableSSEStreamResponse`), `Sources/AppAPI/openapi.yaml` |
| Wiring | `Sources/App/App+build.swift` (one block), `Sources/App/Skills/EventBus.swift`, `Sources/App/Services/APNSNotificationService.swift`, `Sources/App/Models/ApnsCategoryPrefs.swift` |
| Tests | `Tests/AppTests/Hermes/Runs/` — 67 tests in 6 suites |

### Routes — `/v1/hermes/runs`

JWT + `HermesResolutionMiddleware` + the Hermes profile resolver +
`RateLimitMiddleware(.conversationByUser)` + `EntitlementMiddleware(requires: .chat)`.
Mounted only when the endpoint resolver exists (same `LV_SECRET_MASTER_KEY`
gate as BYO Hermes).

| Method | Path | Notes |
| --- | --- | --- |
| POST | `/v1/hermes/runs` | 202 with the persisted run |
| GET | `/v1/hermes/runs` | newest first, `?limit=` capped at 50 |
| GET | `/v1/hermes/runs/:id` | includes `pendingApproval` |
| GET | `/v1/hermes/runs/:id/events` | SSE, `?after=<seq>`; replay then live |
| POST | `/v1/hermes/runs/:id/approval` | body `{"choice":"once\|session\|always\|deny"}` |
| POST | `/v1/hermes/runs/:id/stop` | |

Stable error codes: `hermes_runs_unsupported` (501), `hermes_run_expired`
(410), `hermes_approval_not_pending` (409), `hermes_runs_limit` (429),
`hermes_runs_upstream_error` (502), `prompt_required` (400).

### Design notes worth keeping

- **LuminaVault owns run history.** The Hermes gateway keeps runs in memory
  only (max 1000, 300 s TTL — `api_server.py:711-720`), so every event is
  persisted with a per-run monotonic `seq`. That `seq` is both the replay
  cursor and the SSE resume cursor (`HermesRunDTO.lastSeq`).
- **Watchers are bounded.** One cancellable task per active run, 8 per tenant
  and 32 per process, re-checked after the capability probe suspends the
  actor. `HermesRunsService.run()` re-attaches watchers on boot for active
  rows younger than 300 s and marks the rest `lost`; shutdown cancels and
  *awaits* every watcher before the Fluent pool closes.
- **Re-attach polls, it does not re-subscribe.** Hermes tears the event queue
  down when the first SSE subscriber disconnects, so a second `/events` call
  404s. The watcher falls back to `GET /v1/runs/{id}` and synthesises the
  status change as the event Hermes would have streamed, keeping persistence,
  push and SSE fan-out uniform.
- **`jsonb` + `AnyJSONValue` do not mix.** `AnyJSONValue.init(from:)` tries
  `String` first and the Postgres single-value container hands it the
  column's text, so a bare `AnyJSONValue` Fluent field reads back as
  `.string("{…}")`. `HermesRunEventRow.payload` is therefore
  `[String: AnyJSONValue]`. **Anyone adding another `jsonb` column of type
  `AnyJSONValue` will hit the same bug.**

## Owner steps, in order

1. **Shared tag 5.4.0.** `feat/hermes-p1-dtos` (commit `c239d6f`) already
   contains `feat/hermes-mirror-dtos` (`70ca33b`) — it is two commits ahead
   of `main`, no merge needed.

   ```sh
   cd LuminaVaultShared
   git checkout main && git merge --ff-only feat/hermes-p1-dtos
   git tag v5.4.0 && git push origin main --tags
   ```

   The tag covers both Mirror and Runs DTOs, as the plan allows.

2. **Un-edit the local Shared override before merging the server branch.**
   The worktree was built with `swift package edit LuminaVaultShared --path
   ../LuminaVaultShared-p1`; `Package.resolved` is deliberately *not*
   committed.

   ```sh
   cd LuminaVaultServer
   swift package unedit LuminaVaultShared
   git status   # must show no Package.resolved change
   ```

3. **Bump the pin** in `Package.swift` from `from: "5.2.0"` to `from: "5.4.0"`
   and commit the refreshed `Package.resolved` on its own.

4. **Regenerate Bruno.** `openapi.yaml` gained five paths, a `Hermes Runs`
   tag and eight schemas, but the collection repo is not checked out in this
   worktree, so `make bruno-regen` has **not** been run. Per `CLAUDE.md` it
   must be, and both repos committed together:

   ```sh
   make bruno-regen && cd "$LUMINAVAULT_COLLECTION_PATH" && git diff
   ```

5. **Migrate.** M117 `hermes_runs`, M118 `hermes_run_events`, M119 two
   columns on `apns_category_prefs`. All additive, all `IF NOT EXISTS`, all
   reversible. `fluent.autoMigrate` handles it on deploy; no backfill.

6. **Verify against your own Hermes** over public HTTPS: start a run that
   triggers a shell approval, approve it from the lock screen, confirm the
   run resumes and the completion push lands.

## iOS follow-up (next agent)

- Register `approval` as an **actionable** notification category in
  `Services/Notifications/NotificationsAppDelegate.swift`: two actions
  (Approve once / Deny) that `POST /v1/hermes/runs/:id/approval` in the
  background. The push payload carries `runID`, `hermesRunID`, `status` and a
  comma-separated `choices` list to build the buttons from.
- `runCompleted` is a plain category — no actions needed.
- Add both to the notification-preferences UI (they are opt-outable via M119
  and default to on).
- `API/Hermes/HermesRunsClient.swift`, `Features/Runs/{RunsListView,
  RunDetailView,RunEventRow}.swift`, the SSE consumer on the existing
  `BaseHTTPClient` bytes stream, and a "Run as agent" toggle in the chat
  composer. Snapshot: RunDetail with a pending approval.

Web follow-up is unchanged from the plan: `src/lib/api/hermes-runs.ts`, a
"Hermes runs" tab beside workflow runs on `/studio/runs`, an approval banner.

## Not done in this phase

- **Chat "agent mode".** `HermesRunStartRequest.conversationID` is honoured —
  a system turn linking to the run is appended to the transcript — but the
  `ConversationController` send path does not yet flip to starting a run when
  the tenant's capabilities report `approval_events`. That needs the chat
  composer flag from the iOS side to be meaningful.
- **`make bruno-regen`** (owner step 4 above).
- **The marketing note** `docs/marketing/phase-1-act-from-your-pocket.md`
  (activation event `hermes_run_approved_from_push`) — the plan assigns that
  to a separate agent that reads the finished diff.

## Verification run in this worktree

```
swift build                  # clean
swift test --filter HermesRun # 67 tests, 6 suites, all passing
swiftformat --lint            # clean on every new/changed file
```

Postgres came from `docker compose up -d postgres` (port 5433).
