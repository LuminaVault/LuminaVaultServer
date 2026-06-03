# Card → Job promotion

Branch: `worktree-card-job-promotion`. Hosts ALL card→Job gap fixes.

## What a "Job" is (existing)

A Job == a **vault cron skill**: `skills/<slug>/SKILL.md` (with `schedule:` cron
frontmatter) + a `skills_state` row (`tenant_id, source='vault', name=slug,
enabled, domain, space_id`). `CronScheduler` ticks, fires due skills via
`SkillRunner`, which files each run's markdown result to the vault at
`<space-slug>/jobs/<skill>-<YYYY-MM-DD>.md` (`SkillRunner.fileJobResultIfNeeded`).
`JobsController.create` (`POST /v1/jobs`) is the current authoring path.

## Locked decisions

- **#1 Execution semantics = structured card fields.** Promotion reads explicit
  metadata off the card (`skill_name`/`source`/`cron`|`run_at`/`domain`/`prompt`/
  `space_id`), NOT free-text inference. Deterministic, no LLM at promote time.
- **#2 Result handling = vault-file only.** Reuse `fileJobResultIfNeeded`. NO
  board result cards. Zero flood. (Moots gaps #6 board-version-bump and #8
  result-card recursion — no result cards exist.)

## Gap status (from S864 analysis, code-verified)

| # | Gap | Status |
|---|-----|--------|
| 1 | card→skill mapping | **building** — structured fields |
| 2 | result flood | **resolved by design** — vault-only |
| 3 | P4 space-filing exists | ✅ real (`SkillRunner.fileJobResultIfNeeded`) |
| 4 | SkillRunResult shape | ✅ `.markdown` + `.blocks` (not `.output`) |
| 5 | Jobs column identity fragile | **MOOT (verified)** — no Jobs column exists, no title-matching anywhere; vault-only means no result cards to group; promote works on any card |
| 6 | result-card version bump | MOOT (no result cards) |
| 7 | run-now vs cron dedup | **Already handled (verified)** — manual run → `SkillRunner.persist` stamps `skills_state.last_run_at`; cron `tick` skips `sameMinute`. Residual = narrow race only (stamp at completion, not start) |
| 8 | result-card recursion | MOOT (no result cards) |
| 9 | M72 migration collision | ✅ clear — M71 last committed |
| 10 | one-shot run_at TZ | **TODO (real feature)** — CronScheduler is cron-only; `promoteCard` rejects run_at; one-shot needs ReminderScheduler-style wiring |

## Build order (this branch)

1. **Foundation (#1/#2)** ← current
   - M72: `extra` JSONB on `kanban_cards` (nullable).
   - `CardExtra { job: CardJobConfig? }`, `CardJobConfig` (local App Codable).
   - Refactor: extract `JobAuthoring` from `JobsController.create` (author SKILL.md
     + upsert `skills_state`) so promote reuses it (DRY).
   - `POST /v1/boards/:boardID/cards/:cardID/promote` — validate cron/run_at →
     author job (spec = `prompt` ?? card.body) → write `job_slug`/`promoted_at`
     back to `card.extra`. Idempotent on existing `job_slug`.
   - Tests: promote happy path, invalid cron 400, missing config 400, re-promote
     idempotent, spec falls back to card.body.
2. **#5** column `kind` marker (migration + KanbanColumn field + default-board Jobs col).
3. **#7** unify run-now/cron dedup guard.
4. **#10** one-shot `run_at` UTC handling.
5. **Shared bump + client wiring** — `CardDTO.jobConfig`, promote request DTO,
   iOS promote action. Requires LuminaVaultShared version bump (tag-dep landmine —
   check pin after). Out of THIS commit; server-first.

## Notes / constraints

- `swift test` blocked locally (HER-310 SIGILL + net flakiness); build runs in
  Docker. Verify via build exit code + grep `error:` (see feedback memory).
- Don't add Shared DTOs for server-internal request bodies — promote request is
  decoded from a local server struct until the client step.
