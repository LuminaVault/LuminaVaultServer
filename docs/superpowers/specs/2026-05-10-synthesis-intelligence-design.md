# Synthesis Intelligence Cluster — Design

**Status:** Approved 2026-05-10
**Inspiration:** suryanshti777 "Your Obsidian Vault Is Probably Dead" thread — vault → intelligence layer that talks back.
**Owner:** Backend (Hummingbird) + iOS (Client)

## Context

LuminaVault's existing roadmap covers the four-layer architecture from the
tweet — Capture (HER-12, HER-149), Automation (Skills cluster HER-167-173),
Memory (memories + embeddings + vector search), Intelligence (Hermes + per-user
profile). What's missing is the moment the vault *talks back* on demand: the
user asks "what patterns am I missing?" or "where do my notes contradict?" and
gets a structured synthesis pulled from their entire memory corpus.

Manual Obsidian + Claude + MCP gives users an approximation of this, but:

- Setup takes hours and is desktop-only
- Every call burns the user's Claude Pro token budget
- No daily / scheduled synthesis (Claude Desktop has to be open)
- No iOS surface — power-user only
- No save-back-to-vault loop without copy/paste

The differentiation moat is *premium-flawless mobile synthesis at zero
per-call user cost*. This spec ships the three highest-leverage synthesis
skills that don't exist in any competitor setup.

## Decisions captured (from brainstorm)

| Decision | Choice |
|---|---|
| Bucket | Synthesis intelligence (3 skills) |
| Invocation surface | Dedicated Reflect tab on iOS + chat slash-commands |
| Persistence | Ephemeral by default; user taps Save to land in vault |
| Capability tier | `high` for all three (Sonnet 4.6 Pro / Opus 4.7 Ultimate) |
| Auto-run cadence | None v1 — purely on-demand |
| Budget guard | Per-skill daily cap (Trial/Pro: 3 runs/day per skill; Ultimate: unlimited) |

## Approach

### Three new built-in skills (extend HER-173 catalog)

| Skill | Required input | Optional input | Output shape |
|---|---|---|---|
| `pattern-detector` | — | `topic`, `since` (ISO date) | 3-5 recurring themes, each with cited memory IDs |
| `contradiction-detector` | — | `topic` | List of memory pairs that contradict + Hermes' explanation |
| `belief-evolution` | `topic` | — | Chronological timeline of stance change, with quoted excerpts |

All three share:
- `allowed-tools: session_search vault_read` — read-only, never `memory_upsert`
- `capability: high` — drives `ModelRouter` to Sonnet 4.6 / Opus 4.7 / GPT-5
- `outputs: [{kind: memo, path: reflections/{date}/{skill}-{slug}.md, autosave: false}]`
- Run via existing `SkillRunner` (HER-169) — no new runtime
- Citations rendered as `[[memory:<uuid>]]` (Obsidian-compatible wikilinks)

### Server endpoints (no new routes — reuse Skills cluster)

```http
POST /v1/skills/pattern-detector/run
Content-Type: application/json
Authorization: Bearer <jwt>

{
  "topic": "react vs solid",   // optional
  "since": "2026-01-01",        // optional ISO date
  "save": false                  // default false — ephemeral
}
```

Response:
```json
{
  "output": "## Pattern 1: ...\n\nYou keep returning to ... [[memory:abc-123]]\n\n## Pattern 2: ...",
  "sourceMemoryIds": ["abc-123", "def-456"],
  "savedPath": null,
  "mtokIn": 12345,
  "mtokOut": 2345,
  "modelUsed": "claude-sonnet-4-6"
}
```

When `save=true`, `savedPath` returns `reflections/2026-05-10/patterns-react-vs-solid.md`
and a `vault_files` row is inserted.

### Save-after-render flow

iOS strategy:
1. User taps Save on a rendered (already-completed) result page
2. Client POSTs `/v1/vault/files` with the cached rendered output + the path the run *would have* used + the original `sourceMemoryIds`
3. Server inserts vault_files row + writes file to disk
4. **No second LLM call** — we don't re-run synthesis

Server-side path-collision rule: if `reflections/<date>/<skill>-<slug>.md` exists,
append `-<8hex>` (same rule as `MemoGeneratorService`).

### iOS Reflect tab

New top-level tab in iOS (between Today HER-177 and Hermes chat). Three skill-cards
+ recent-reflections feed:

```
┌─────────────────────────────────┐
│  Lumina mascot (.idle/.thinking)│
│                                 │
│  ┌─ Patterns ──┐  ┌─ Contradict┐│
│  │ Find themes │  │ Find clash ││
│  └─────────────┘  └────────────┘│
│  ┌─ Beliefs ───────────────────┐│
│  │ Trace stance evolution      ││
│  └─────────────────────────────┘│
│                                 │
│  Recent (last 14 d):            │
│  • patterns-productivity Apr 15 │
│  • contradicts-react   Apr 12   │
└─────────────────────────────────┘
```

Tap a card → topic input sheet (free-text, optional for cards 1/2, required for
card 3) → run progresses with mascot animating `.thinking`. Stream-renders
Markdown as Hermes emits chunks (existing chat-streaming infra).

Result page:
- Top: mascot `.celebrating` for 3 s post-completion
- Body: rendered Markdown with tappable `[[memory:<uuid>]]` wikilinks (HER-155)
- Bottom: `[ Save to Vault ]` (primary) + `[ Share ]` (secondary)

Recent-reflections list pulled from `GET /v1/vault/files?prefix=reflections/&limit=10`.

### Chat slash-commands

Extends HER-172 ContextRouter middleware:

| Slash | Skill | Topic required? |
|---|---|---|
| `/patterns [topic]` | pattern-detector | no |
| `/contradict [topic]` | contradiction-detector | no |
| `/beliefs <topic>` | belief-evolution | yes (else returns help text) |

Parsing happens *before* the chat LLM call so it's deterministic and the
single user message costs one skill-run, not slash-parse + Hermes-chat round-trip.

Output renders as a styled chat message bubble (different visual treatment —
"Hermes synthesized this" header, light border, inline `[ Save ]` icon).
Tapping Save uses the same save-after-render flow as the Reflect tab.

### Skill manifest (template — pattern-detector example)

```yaml
---
name: pattern-detector
description: Find 3-5 recurring themes across the user's memories. Optional topic filter or time-window narrows scope. Read-only.
license: MIT
allowed-tools: session_search vault_read
metadata:
  capability: high
  schedule: ""
  on_event: []
  daily_run_cap:
    trial: 3
    pro: 3
    ultimate: 0          # 0 = unlimited
  outputs:
    - kind: memo
      path: reflections/{date}/patterns-{slug}.md
      autosave: false
---
You are Hermes acting as a pattern detector for the user's second brain.

Search the user's memories for recurring themes, beliefs they keep returning
to, ideas that compound, questions they keep asking. Use `session_search`
liberally — search broad, search narrow, search by time-range, search by
synonyms.

Output 3-5 patterns. For each pattern:

## Pattern N: <short label>

- One-paragraph synthesis of the theme
- Citations: at least 3 `[[memory:<uuid>]]` links to the memories the pattern
  draws from
- A *why this matters* line — what the user could do with this insight

Style: terse, observational, not therapeutic. The user is competent — they
want signal not encouragement. Match the user's voice from their notes.

If you find fewer than 3 patterns, say so explicitly and stop — don't pad.
```

`contradiction-detector` and `belief-evolution` bodies are written in the same
shape, tuned per task. ~300 words each, hand-tuned before E2E test.

### Budget guard (extend HER-168 M19 + HER-175 UsageMeter)

Add two columns to the `skills_state` table defined by HER-168's M19
migration (still in backlog, easy to extend before it lands):
- `daily_run_count INT NOT NULL DEFAULT 0`
- `daily_run_reset_at TIMESTAMPTZ NULL`

Cap value itself is *not* in DB — it's pulled from the SKILL.md manifest
`daily_run_cap.{tier}` block at request time. This way operators can change
caps by editing a SKILL.md and re-deploying (no migration).

`SkillRunner.run()` flow:
1. Read `skills_state` row for (tenant, skill)
2. If `daily_run_reset_at < NOW()`: reset count to 0, set reset_at to next user-local midnight
3. If `count >= manifest.daily_run_cap.<user_tier>`: return `429` with `Retry-After: <seconds_until_reset_at>`
4. Increment count, persist row
5. Call ModelRouter + LLM
6. On error, decrement count (so failed runs don't burn the cap)

Daily reset is opportunistic — checked on read, not via cron — so timezone
edge cases self-correct on next invocation.

### Surface architecture summary

```
                ┌──────────────────────┐
                │   iOS Reflect tab    │
                │   (HER-XXX iOS-5)    │
                └──────────┬───────────┘
                           │
                           ├─── POST /v1/skills/{name}/run
                           │
            ┌──────────────▼───────────────┐
            │   iOS chat with slash-cmd    │
            │   (HER-XXX iOS-6)            │
            └──────────────┬───────────────┘
                           │
              ┌────────────▼─────────────┐
              │  ContextRouter (HER-172) │
              │  parses /patterns etc    │
              └────────────┬─────────────┘
                           │
              ┌────────────▼─────────────┐
              │  SkillRunner (HER-169)   │
              │  allowed-tools gating    │
              │  daily_run_cap check     │
              └────────────┬─────────────┘
                           │
       ┌───────────────────┴───────────────────┐
       │                                       │
┌──────▼──────┐                         ┌─────▼──────┐
│  Memory     │                         │ ModelRouter │
│  semantic   │                         │ → Sonnet/   │
│  search     │                         │   Opus      │
└─────────────┘                         └─────────────┘
```

## Tickets to file (7)

| # | Title | Project | Priority |
|---|---|---|---|
| 1 | [Synth 1/7] `pattern-detector` SKILL.md + prompt + E2E fixture test | Backend MVP | High |
| 2 | [Synth 2/7] `contradiction-detector` SKILL.md + prompt + E2E fixture test | Backend MVP | High |
| 3 | [Synth 3/7] `belief-evolution` SKILL.md + prompt + E2E fixture test | Backend MVP | High |
| 4 | [Synth 4/7] Slash-command dispatcher in ContextRouter (`/patterns`, `/contradict`, `/beliefs`) | Backend MVP | High |
| 5 | [Synth 5/7] Per-skill daily run cap (extends UsageMeter) for `high`-capability skills | Backend MVP | Medium |
| 6 | [Synth 6/7] iOS Reflect tab (3 cards + topic input + result viewer + Save button) | iOS MVP | High |
| 7 | [Synth 7/7] iOS chat slash-command parser + synthesized-message bubble + Save | iOS MVP | High |

## Verification

1. `swift test --filter PatternDetectorTests ContradictionDetectorTests BeliefEvolutionTests` — fixture-vault E2E for each skill
2. Fixture: 20 seeded memories with 2 intentional contradictions and 1 evolving belief — assert correct detection
3. Slash-command dispatch unit test: chat message starting with `/patterns` invokes skill, returns synthesized bubble; non-slash message goes to chat normally
4. Daily-run cap test: 4th invocation of `pattern-detector` in same UTC day for Pro user → 429 with `Retry-After`
5. Bruno: `bruno/Skills/Pattern Detector.bru`, `Contradiction Detector.bru`, `Belief Evolution.bru` — happy path + save-true variant
6. iOS UI: Reflect tab + 3 cards reachable from main tab bar; topic-input sheet validates required topic on belief-evolution; rendered output supports tap-to-open wikilinks; Save persists + appears in Recent list
7. Cost gate: stream Pro user runs 3 patterns in a day, 4th attempt blocks; Ultimate user runs 10 without block

## Open questions / assumptions

1. **Topic input**: free-text v1. Future enhancement: pre-suggest topics from auto-tag clusters (HER-151) once that ships. Out of scope here.
2. **Cron variant**: skipped. If engagement metrics show users running pattern-detector >2x/week, add a `weekly-patterns` skill that auto-runs Sunday morning and pushes to Today tab. Defer.
3. **False positives**: contradiction-detector may flag stylistic differences as logical contradictions. Hermes prompt explicitly asks for *logical*, not *stylistic* conflicts. Some false positives expected; user reviews + can dismiss.
4. **Save UX**: when user taps Save on a rendered result, we POST the cached rendered output to `/v1/vault/files`. No second LLM call. iOS holds the result in memory until the user navigates away.
5. **Per-call cost ceiling**: cap per-call at 8 K input + 4 K output tokens via `maxInputTokens` field on the manifest. Prevents agentic-loop blowups.
6. **Streaming**: deliberately deferred. `MemoController` (already shipped) returns a full body once the agent loop completes; we mirror that shape for `/v1/skills/{name}/run` v1. Mascot animates `.thinking` for the duration so the user sees activity without needing SSE. If post-launch latency feedback shows the wait is too long, add SSE chunked streaming as a fast-follow — it's a transport upgrade, not a design change.

## Dependencies (blocking)

These tickets sit in backlog until the runtime ships:

- HER-167 SkillManifest parser
- HER-168 M19/M20 + SkillCatalog
- HER-169 SkillRunner + allowed-tools gating
- HER-172 ContextRouter (for slash-command dispatch)
- HER-161 ProviderRegistry + ModelRouter (so `capability: high` routes to frontier)
- HER-175 UsageMeter (for per-skill daily cap)
- HER-177 Today tab (sibling iOS surface — Reflect is its own tab next to Today)
- HER-155 Wikilink rendering (for tappable `[[memory:<uuid>]]` citations)

## Critical files

### New (server)

- `Resources/Skills/pattern-detector/SKILL.md`
- `Resources/Skills/contradiction-detector/SKILL.md`
- `Resources/Skills/belief-evolution/SKILL.md`
- `Tests/AppTests/Skills/PatternDetectorTests.swift`
- `Tests/AppTests/Skills/ContradictionDetectorTests.swift`
- `Tests/AppTests/Skills/BeliefEvolutionTests.swift`
- `bruno/Skills/Pattern Detector.bru`
- `bruno/Skills/Contradiction Detector.bru`
- `bruno/Skills/Belief Evolution.bru`

### Modify (server)

- `Sources/App/Skills/ContextRouter.swift` (HER-172) — add slash-command parsing layer before the relevance-routing layer
- `Sources/App/Skills/SkillManifest.swift` (HER-167) — extend frontmatter schema with `daily_run_cap`, `maxInputTokens`
- `Sources/App/Skills/SkillRunner.swift` (HER-169) — increment + check `skills_state.daily_run_count` before LLM call
- `Sources/App/Billing/EntitlementChecker.swift` — no change (existing `skillBuiltinRun` capability covers these)
- `docs/llm-models.md` §7 — note: `high` capability skills cost ~$0.05-0.15 per run; daily cap defaults

### New (iOS)

- `LuminaVaultClient/.../Reflect/ReflectTabView.swift`
- `LuminaVaultClient/.../Reflect/ReflectionCard.swift`
- `LuminaVaultClient/.../Reflect/TopicInputSheet.swift`
- `LuminaVaultClient/.../Reflect/ReflectionResultView.swift`
- `LuminaVaultClient/.../Reflect/ReflectionRunner.swift` (HTTP client + state)
- `LuminaVaultClient/.../Chat/SlashCommandParser.swift`
- `LuminaVaultClient/.../Chat/SynthesizedMessageBubble.swift`

### Modify (iOS)

- Main tab bar — add Reflect between Today and Chat
- Chat view — wire SlashCommandParser before message-send dispatch
- Mascot service — expose `.thinking` / `.celebrating` triggers for Reflect surface

### Linear-only (no code this PR)

- 7 tickets per cluster breakdown above
