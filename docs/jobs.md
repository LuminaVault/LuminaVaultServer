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
| 1 | **Auto kb-compile per user** — sweep users with unprocessed captures, run kb-compile on their behalf so memories are always current. | nightly 02:00 user-local | server | Day 1 of beta | swift-cron ServiceLifecycle Service iterating `vault_files WHERE processed_at IS NULL`. Requires column added to schema. |
| 2 | **Daily Lumina brief push** — synthesize "yesterday's themes" + "today's nudges" into a memo, push as APNS digest. | 07:00 user-local | server → APNS | Day 7 of beta (after #1 has data) | swift-cron + `APNSNotificationService.notifyDigest`. Use the user's stored timezone. |
| 3 | **Hermes profile reconcile** — rebuild missing profile rows / dirs, reap orphans. | 04:00 daily | ops | Already shipped reconciler — run when needed | Host cron: `curl -X POST -H "X-Admin-Token: $T" /v1/admin/hermes-profiles/reconcile`. |
| 4 | **Orphan vault file reaper** — find `vault_files` rows whose disk file is missing (or vice versa), soft-delete the orphan. | weekly | server | Once first incident occurs | swift-cron sweeping both surfaces. Soft-rename to `_deleted_<ts>_<original>` for 30-day grace. |
| 5 | **Embedding refresh** — re-embed every memory after switching `EmbeddingService` provider (e.g. Deterministic → OpenAI). | one-shot per swap | ops | When real embeddings land (HER-134) | One-shot admin endpoint `POST /v1/admin/embeddings/refresh`. Streams progress over SSE. |
| 6 | **Apple Health correlation insights** — read last 7 days of `health_events` + memories per user, ask Hermes "find correlations" and emit a single synthesized memory. | nightly | server | After ≥ 30 days of HealthKit ingest per user | swift-cron: pull → run agent loop with `session_search` + `memory_upsert` → save with `tags=["correlation","weekly"]`. 1 row/user/week. |
| 7 | **Spaced-repetition memory review** — pick N memories due for review based on Leitner schedule, push as a quiz APNS notification. | per-user, configurable (default daily 18:00) | server → APNS | After SR ticket lands | swift-cron + per-user schedule row. Skip on weekends if user opts in. |
| 8 | **Memory pruning** — score memories by access frequency + recency, archive low-score rows older than N months. | monthly | server | After ≥ 1k memories per user | swift-cron with score threshold. Uses `memories.score FLOAT` (HER-XXX). Archive = move to `_archived` table; nothing is `DELETE`'d. |
| 9 | **Link enrichment** — on-capture, fetch oEmbed (YouTube), oG meta tags, transcript when available; rewrite the captured MD with structured frontmatter. | event-driven (NOT cron) | server | Day 1 of beta — high impact, low effort | Capture controllers enqueue a backfill task on a `Service`-managed worker actor. `URLSession` to oEmbed endpoints. |
| 10 | **iOS background HealthKit pull** — pull new HealthKit samples + POST to `/v1/health` while the app is suspended. | every 30 min when on Wi-Fi | client | Already shipped (HER-38) | `BGAppRefreshTask` + `HKObserverQuery` (already wired in `HealthKitService`). |

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
