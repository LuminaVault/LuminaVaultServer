# Hand-off — Hermes Companion Phase 2 "Collect" (server, branch `feat/hermes-p2-collect`)

Status: implemented and tested on the server; **not pushed, not tagged, not
merged**. The branch builds only against a local `LuminaVaultShared` checkout
until the Shared tag below exists.

Phase 2 closes the loop the Mirror opened. The Mirror could see the tenant's
Hermes cron jobs; it could not read what they produced, could not change them,
and the Today tab that was supposed to show their output was a stub returning
an empty list. After this branch a run on the user's own Hermes lands in the
vault, on the Today feed and in a queryable run history, and the jobs
themselves are fully editable from LuminaVault.

## Owner steps, in order

1. **Order the two Shared branches first.** `feat/hermes-p1-dtos` (`c239d6f`)
   and `feat/hermes-p2-dtos` (`c9dbe2c`) are **siblings**, both branched from
   `70ca33b` (the 5.3.0 commit). They are not a chain, so tagging them in
   sequence needs a merge or a rebase:
   - Tag **`5.4.0`** from `feat/hermes-p1-dtos` (Phase 1 runs/approvals DTOs).
   - Then rebase (or merge) `feat/hermes-p2-dtos` onto that, and tag **`5.5.0`**
     from the result. `5.5.0` is what **this** branch needs — it contains
     Phase 1's DTOs as well, so bumping the server to `5.5.0` covers both.
   - Both steps are additive minors: nothing existing changed shape.
2. **Bump the server pin** in `LuminaVaultServer/Package.swift`. It currently
   reads `from: "5.2.0"`; Phase 1 already needs `5.4.0`, and **this branch
   needs `5.5.0`**:
   `.package(url: "https://github.com/LuminaVault/LuminaVaultShared.git", from: "5.5.0")`
   (update the comment above it), then `swift package resolve` and commit
   `Package.swift` + `Package.resolved`.
   Local builds before the tag: `swift package edit LuminaVaultShared --path ../LuminaVaultShared`.
   **`Package.resolved` is deliberately not committed on this branch** — it is
   dirty from that edit and every commit here excludes it.
3. **Regenerate the Bruno collection.** `openapi.yaml` gained eleven paths and
   nine schemas on this branch, and `make bruno-regen` was **not** run: the
   generated collection lives in a sibling repo
   (`LuminaVaultCollection`, resolved via `LUMINAVAULT_COLLECTION_PATH`) that
   this work was scoped out of. Run it after merge and commit the result there.
4. **Migrations:** M120 (`hermes_job_runs` + the two `hermes_mirrored_jobs`
   collect columns) and M121 (`hermes_mirror_webhooks`) run with
   `fluent.autoMigrate` / `make migrate`. Both are additive and both revert
   cleanly. No new config keys.
5. **Infra:** no manifest changes. The webhook adds an **inbound** public route
   (`POST /v1/hermes/mirror/webhook/{token}`); nothing else about ingress
   changes, and the feature is opt-in per tenant.
6. **Merge order:** this branch sits on top of `feat/hermes-mirror`. Merge that
   first (see `docs/HANDOFF-hermes-mirror.md`), then Phase 1, then this.

## What shipped

**Collect (already on the branch when this hand-off was written).**
`HermesMirrorCollect.swift` pulls finished cron runs off the tenant's Hermes
into `hermes_job_runs`, files each non-empty output into the vault as
`raw/jobs/<job-slug>/<yyyy-MM-dd-HHmm>.md` (provenance `hermes-job`), and logs
a `skill_run_log` row so the run shows up wherever local skill runs do.
Idempotency rests on `hermes_job_runs (tenant_id, hermes_run_key)` being
unique; the per-job high-water mark is only a read optimisation. The refresh
worker runs the same pass every tick.

**The Today feed is real (`GET /v1/skills/outputs`).** HER-177 shipped it as a
stub. It now unions local `skill_run_log` runs that produced markdown with
collected `hermes_job_runs`, newest first, in one statement. The local arm
excludes `source = 'hermes'` because the collector writes those rows too and
the job-runs arm carries the same content *plus* `vaultFilePath`. Each arm is
limited before the union, so the query sorts at most `2 × limit` rows and rides
the existing `(tenant_id, started_at DESC)` indexes. `since` and `before` are
both exclusive and `nextCursor` (present only on a full page) round-trips into
`before`. A failed run with no markdown falls back to its error text and a
`<name> failed` headline. The active-run flag bounds pending local runs to an
hour so a crashed run cannot pin the client on "thinking".

**Full job control.** The transports already had create/update/pause/resume/
trigger/delete; nothing exposed them. `HermesMirrorJobControl.swift` adds thin
service wrappers and the controller routes. Every mutation happens on Hermes
first and mirrors what Hermes answered, so a failed upstream call leaves the
mirror untouched, and `GET /jobs` reflects the change with no intervening sync.
That re-save is only safe because `apply(_:)` reassigns `raw` from the
response — see the jsonb note below. `GET /jobs/{id}/runs` reads stored rows
only (so it answers while the tenant's Hermes is offline) and now resolves
`vaultFilePath`, which `HermesJobRun.dto()` previously hard-coded to nil.

**Optional inbound webhook (M121).** The tenant's Hermes can POST to
`/v1/hermes/mirror/webhook/{token}` when a job finishes; LuminaVault collects
that job immediately instead of waiting for the next worker tick. **Pull stays
the source of truth** — the push runs the identical idempotent collect, so a
webhook that is never configured, never arrives, arrives late or arrives twice
changes latency and nothing else.

## Routes added

| Method | Path | Notes |
| --- | --- | --- |
| `POST` | `/v1/hermes/mirror/jobs` | Full Hermes `CronJobCreate` body |
| `PUT` | `/v1/hermes/mirror/jobs/{id}` | Partial update; empty body → 400 |
| `POST` | `/v1/hermes/mirror/jobs/{id}/pause` | |
| `POST` | `/v1/hermes/mirror/jobs/{id}/resume` | |
| `POST` | `/v1/hermes/mirror/jobs/{id}/trigger` | Fires on Hermes' next tick; does not wait for output |
| `DELETE` | `/v1/hermes/mirror/jobs/{id}` | 204; collected runs are kept |
| `GET` | `/v1/hermes/mirror/jobs/{id}/runs` | `?limit=` 1–200, default 50; stored rows only |
| `GET` | `/v1/hermes/mirror/webhook` | Credential without the secret |
| `POST` | `/v1/hermes/mirror/webhook` | Rotate; returns the secret **once** |
| `POST` | `/v1/hermes/mirror/webhook/{token}` | **Public.** HMAC-signed push |
| `GET` | `/v1/skills/outputs` | Existed as a stub; now real, and gained `before` |

Stable error codes added: `hermes_job_name_required`,
`hermes_job_schedule_required`, `hermes_job_update_empty` (400),
`hermes_job_not_found` (404), `hermes_webhook_unauthorized` (401),
`hermes_webhook_invalid_payload` (400), `hermes_webhook_not_configured` (404),
`hermes_admin_config_rw_required` (409). The Phase-1 codes
(`hermes_mirror_invalid_path`, `hermes_mirror_busy`, the `hermes_dashboard_*`
family) are unchanged and still apply to every route here.

## `admin_config_rw` — the webhook precondition

Minting a webhook credential requires the tenant's Hermes to report
`admin_config_rw` on `/api/status`. The reason is practical rather than
defensive: the user has to be able to store the URL and secret *on their own
Hermes* for the push to ever fire, and that is a config write. Handing out a
credential to a Hermes that cannot save it is a dead end that looks like a
broken feature.

- Hermes advertises it as a flat `admin_config_rw` boolean or inside a
  `capabilities` list, depending on version; older builds say nothing, which
  reads as "no".
- Tenants on the **managed** Hermes always qualify — LuminaVault owns that
  config on the shared PVC, so the capability is the transport.
- Anything else degrades to `409 hermes_admin_config_rw_required` and keeps
  polling. Collection is unaffected either way.

Webhook envelope, for whoever writes the Hermes-side sender:
`X-Webhook-Signature-V2: hex(HMAC-SHA256(secret, "<unix seconds>.<raw body>"))`,
`X-Webhook-Timestamp: <unix seconds>`, 300 s window, body
`{"job_id": "..."}`. It is the same scheme the workflow hooks use. Unknown
token, bad signature and a stale or missing timestamp all answer the same 401
with the same message so a sender cannot probe for live tokens.

## The jsonb trap (still live, worth knowing before touching this code)

`hermes_mirrored_jobs.raw` is a `JSONValue` on a `jsonb` column. PostgresNIO
hands a `jsonb` column to a single-value-container type as its raw JSON *text*,
so loading a row and saving it back wraps the document in another JSON string —
a little more corrupt on every tick. Two rules follow, both enforced in the
code and asserted in tests:

- The collect pass writes its two columns with raw SQL (`markCollected`), never
  `job.save()`.
- Job control may save the row, but only after `apply(_:)` has reassigned `raw`
  from a live Hermes response.

`HermesJobRun.tokens` avoids the same trap by being a keyed `Codable` struct
rather than a `JSONValue`.

## Deliberately left undone

- **Storing a run straight from the webhook body** (`push:<runKey>`, which
  `HermesJobWebhookPayload` documents). The push names the job; the collect
  reads the truth. A pushed body is unverified against Hermes' own run listing
  and writing it would burn the run key the poller relies on for idempotency.
  The fields are on the DTO for a future slice; today only `job_id` is acted on.
- **`make bruno-regen`** — see owner step 3.
- **Exposing `admin_config_rw` on `HermesDashboardCapabilitiesDTO`.** It is
  server-side only (`HermesDashboardStatus`) so Phase 2 needed no extra Shared
  change. A client that wants to hide the "enable push" button before calling
  rotate will need that field added to the DTO.
- **Client work.** iOS and web consume these routes from `openapi.yaml` /
  Shared `5.5.0`; nothing in either client was touched.

## Verification run (2026-09-04, macOS, local Postgres)

- `swift build` — clean.
- `swift test --filter "HermesMirror|CronBridge|SkillOutputs|HermesJobRun"` —
  **61 tests in 9 suites, all passing** (`SkillOutputsShapingTests`,
  `SkillOutputsFeedTests`, `HermesMirrorControllerTests`,
  `HermesMirrorWebhookControllerTests`, `HermesMirrorServiceTests`,
  `HermesMirrorServiceHelperTests`, `HermesMirrorRefreshWorkerTests`,
  `HermesJobRunModelTests`, `M114HermesMirrorTests`).
- `swiftformat` clean on every touched file; `swiftlint` clean on every new
  file (the repo's `.swift-version` warning is expected noise, and the
  pre-existing `App+build.swift` warnings are untouched).
- `make test` (Docker full suite) not run.
