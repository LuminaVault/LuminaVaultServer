# LuminaVaultServer — Scheduled Jobs

A taxonomy of recurring, LLM-executable tasks the platform should run on
its own. Nothing here is implemented yet beyond what's noted; this file
documents the *surface* so we can wire individual jobs as they become
worthwhile.

The pattern: most jobs are admin-side hits against existing endpoints
driven by **host cron**, OR in-process tasks managed by a Swift Service
(future `swift-cron` integration). Some are client-side `BGAppRefreshTask`
work, not server jobs at all.

## Job catalog

| # | Job | Cadence | Owner | When to wire | Recommended impl |
|---|---|---|---|---|---|
| 1 | **Auto kb-compile per user** — sweep users with unprocessed captures, run kb-compile on their behalf so memories are always current. | nightly 02:00 user-local | server | **Shipped** | `AutoKBCompileJob` ServiceLifecycle service iterating `vault_files WHERE processed_at IS NULL`. Uses `users.timezone`, stamps `processed_at` only after successful Hermes compile, and retries transient failures at the next scheduled run. |
| 2 | **Daily Lumina brief push** — synthesize "yesterday's themes" + "today's nudges" into a memo, push as APNS digest. | 07:00 user-local | server → APNS | Day 7 of beta (after #1 has data) | swift-cron + `APNSNotificationService.notifyDigest`. Use the user's stored timezone. |
| 3 | **Hermes profile reconcile** — rebuild missing profile rows / dirs, reap orphans. | 04:00 daily | ops | Already shipped reconciler — run when needed | Host cron: `curl -X POST -H "X-Admin-Token: $T" /v1/admin/hermes-profiles/reconcile`. |
| 4 | **Orphan vault file reaper** — find `vault_files` rows whose disk file is missing (or vice versa), soft-delete the orphan. | weekly | server | Once first incident occurs | swift-cron sweeping both surfaces. Soft-rename to `_deleted_<ts>_<original>` for 30-day grace. |
| 5 | **Embedding refresh** — re-embed every memory after switching `EmbeddingService` provider (e.g. Deterministic → OpenAI). | one-shot per swap | ops | When real embeddings land (HER-134) | One-shot admin endpoint `POST /v1/admin/embeddings/refresh`. Streams progress over SSE. |
| 6 | **Apple Health correlation insights (HER-146)** — read last 7 days of `health_events` + memories per user, ask Hermes "find correlations" and emit a single synthesized memory. | nightly | server | **Scaffold shipped** — `POST /v1/admin/health/correlate` driven by host cron. Wire the crontab line once ≥ 30 days of HealthKit ingest per user is realistic. | Host cron: `curl -X POST -H "X-Admin-Token: $T" $BASE/v1/admin/health/correlate`. Skips users with <30 days of HealthKit data. Idempotent on the 7-day window via `correlation`+`weekly` tag probe. Saves a single memory with `tags=["correlation","weekly"]`. Tool-calling agent loop (`session_search` for older context) is a follow-up — current impl is single-shot chat. |
| 7 | **Spaced-repetition memory review** — pick N memories due for review based on Leitner schedule, push as a quiz APNS notification. | per-user, configurable (default daily 18:00) | server → APNS | After SR ticket lands | swift-cron + per-user schedule row. Skip on weekends if user opts in. |
| 8 | **Memory pruning (HER-147)** — score memories by access frequency + recency + query hits, archive low-score rows older than N months. | monthly | server | **Scaffold shipped** — `POST /v1/admin/memory/prune` driven by host cron. Wire once a tenant accumulates >1k memories. | Host cron: `curl -X POST -H "X-Admin-Token: $T" $BASE/v1/admin/memory/prune`. Recomputes scores per tenant, then archives rows where `score < threshold AND created_at < now - minAgeMonths` into `memories_archive` (no `DELETE`). Score = `2*ln(1+access_count) + 3*ln(1+query_hit_count) + 1*exp(-ageDays/30)`. Query-hit counter auto-increments inside `MemoryRepository.semanticSearch`. |
| 9 | **Lapse archiver** — expire trials/subscriptions, archive long-lapsed vaults, and hard-delete archived users after the GDPR window. | nightly 03:00 UTC | server | **Shipped dark with billing B3a** — runs as an in-process `Service` when Fluent is enabled. | `LapseArchiverJob`: active expired users become `lapsed`; `lapsed` older than 90 days move from `vault.rootPath/tenants/<id>` to `billing.coldStoragePath/<id>` and become `archived`; `archived` older than 365 days are hard-deleted with cold-storage cleanup. `billing.coldStoragePath` defaults to `<vault.rootPath>/cold-storage`. |
| 10 | **Link enrichment** — on-capture, fetch oEmbed (YouTube), oG meta tags, transcript when available; rewrite the captured MD with structured frontmatter. | event-driven (NOT cron) | server | Day 1 of beta — high impact, low effort | Capture controllers enqueue a backfill task on a `Service`-managed worker actor. `URLSession` to oEmbed endpoints. |
| 11 | **iOS background HealthKit pull** — pull new HealthKit samples + POST to `/v1/health` while the app is suspended. | every 30 min when on Wi-Fi | client | Already shipped (HER-38) | `BGAppRefreshTask` + `HKObserverQuery` (already wired in `HealthKitService`). |

## Implementation order

When time + budget arrives, build in this order:

1. **#9 Link enrichment** (event-driven, no cron infra needed, immediate quality boost)
2. **#1 Auto kb-compile** (the quietly-magic feature — vault stays current without user action)
3. **#3 Hermes profile reconcile** as host cron (1-line crontab, zero risk)
4. **#2 Daily Lumina brief** (compounds with #1 — first thing user sees in the morning)
5. **#6 Apple Health correlation** (the "wow" insight that's hard to copy)
6. Everything else — only when there's evidence of need

## When NOT to use swift-cron

| Scenario | Better choice |
|---|---|
| One-shot ops task (reconcile, embedding refresh) | host cron + admin endpoint |
| Triggered by user action (link enrichment) | in-process worker actor, not cron |
| iOS-only timing (HealthKit refresh) | `BGAppRefreshTask` |
| Multi-replica deployment | external Cloudflare Worker or k8s CronJob, not in-process |

swift-cron is for *in-process server-side tasks that don't need to survive
horizontal scaling*. As soon as the deployment goes multi-replica, every
in-process cron job double-fires unless backed by a leader-election lock —
re-platform onto k8s CronJob or similar at that point.

## Skill-based jobs (future)

A future direction (see Linear ticket "Skills system, obsidian-skills
inspired"): each scheduled job is itself a per-user **skill**. The user
configures their schedule + which skill runs. Examples:

- "Every Sunday 18:00 — write me a weekly review memo"
- "Every morning 07:00 — find what's blocking me from yesterday's TODOs"
- "When my recovery score drops below 60 — ask me one mood question"

This collapses #1 + #2 + #6 + #7 from the catalog above into a single
generic skill-runner. Worth doing post-MVP, when the skill primitive
exists.

### Status: scaffold landed (HER-148)

`Sources/App/Skills/` ships the runtime scaffold:

- `SkillManifest` + `SkillManifestParser` (HER-167)
- `SkillCatalog` actor — builtin + vault precedence (HER-168)
- `SkillRunner` actor — allowed-tools gating (HER-169)
- `CronScheduler` — in-process Service (HER-170, single-replica only)
- `EventBus` — vault/health/memory publishers (HER-171)
- `ContextRouter` middleware — Pro-only, off by default (HER-172)
- 5 built-in `Resources/Skills/<name>/SKILL.md` (HER-173)

DB: `M19_CreateSkillsState` + `M20_CreateSkillRunLog`.
Route: `POST /v1/skills/:name/run` (jwt + `skillRunByUser` rate-limit).

Once HER-167…HER-173 land, jobs #1 (kb-compile), #2 (digest push), #6
(weekly-memo) and #9 (capture-enrich) are superseded by the equivalent
skills and these entries can be retired from this catalog.

### Status: auto kb-compile shipped

`AutoKBCompileJob` is registered in `appServices` when Fluent is enabled and
`jobs.autoKbCompile.enabled` is not `false`.

Config:

- `jobs.autoKbCompile.enabled` — default `true`
- `jobs.autoKbCompile.hour` — default `2`
- `jobs.autoKbCompile.minute` — default `0`
- `jobs.autoKbCompile.maxConcurrentUsers` — default `2`
- `jobs.autoKbCompile.batchLimit` — default `50`
