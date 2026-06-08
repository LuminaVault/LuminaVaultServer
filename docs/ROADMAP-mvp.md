# LuminaVault — MVP Scope & Philosophy

Positioning: a modern, AI second brain — **Obsidian's structure (Spaces, vault,
wikilinks) + a real LLM agent (Hermes)** — that feels like a **living LLM Wiki**:
save things (especially links), and the AI reasons over them.

Guiding principle: **nail the core loop; don't overbuild.** Avoid both
over-engineering early and under-delivering the "intelligent second brain"
promise.

## Opinionated stances

1. **Core = link → LLM reasoning. Day-one, non-negotiable.** Already mostly
   built: share/paste a link → `URLEnrichmentService` (+ jina) fetches the body
   → `vault_file` + embedded `memory` → chat grounds + cites it. The hero loop:
   *share a link → "Saved to {Space}" → ask chat → grounded, cited answer.*
   Polish this one loop until it's magic.
2. **Vault: real from day-one, but thin.** Spaces + notes + link-notes +
   grounding + graph are the differentiator (all shipped). Keep editing/sync
   minimal — do not chase full Obsidian editing.
3. **Importing: yes, early + low-friction.** Bookmarks (onboarding wedge),
   choose-Space (done), multi-file / `.md` / Obsidian vault import (shipped).
4. **Obsidian: one-way import early (done), export/sync later.** Frictionless
   "bring your vault in" is a real wedge; two-way sync / a plugin is post-6mo.
5. **Managed flawless = default; BYO = power-user, secondary.** ~95% want
   zero-config managed brilliance. BYO-Hermes is the moat (privacy / own credits
   / full skills) — keep it working + documented (done), off the main onboarding
   path. Remote-Hermes / vault import is the BYO power-bridge, not step 1.

## Phased plan

### MVP (now → 3 months) — nail the core
- **Link ingest + LLM reasoning** over saved links — hero loop; share-sheet,
  citations, "saved → ask" affordance. *(core promise)*
- **Basic vault** — Spaces, notes, grounding, Brain graph *(done; polish
  empty-states + the saved→ask handoff)*.
- **Bookmark import** in onboarding *(`/v1/import/bookmarks` exists)*.
- **Multi-file / Obsidian import** *(shipped `/v1/import/vault-bulk` + iOS
  Import Vault; polish zip/folder UX + dedup)*.
- **Excellent managed experience** — model reliability (the BYOK/DeepSeek/error-
  surfacing work), fast first-token, clean failures.

### 3–6 months — power + automation
- **Skills/Jobs from iOS** — see + create Hermes cron jobs by chatting, TUI-parity
  *(see `plan-hermes-cron-bridge.md`)*.
- **BYO-Hermes smooth-ish** — core done; named tunnel, in-app guided setup,
  health surfacing.
- **Ongoing vault sync** — cron push of changed `.md`, not one-shot import.
- **Skills / insights surfacing.**

### Deferred (post-6 months)
- Two-way Obsidian sync / plugin.
- Full remote-Hermes management mirror (sessions / memory / skills install).
- Multiple BYO endpoints, mTLS, skills marketplace.

## Per-item verdict (the questions asked)

| Item | Verdict |
|---|---|
| Link ingestion + LLM reasoning | **MVP — the hero loop** (mostly built; polish) |
| Basic vault (files, Spaces) | **MVP** (shipped; polish) |
| Browser bookmark import | **MVP** (onboarding wedge) |
| Multi-file import | **MVP** (shipped) |
| Obsidian compat / migration | **MVP: one-way import** (shipped); sync/export later |
| Full remote-Hermes import | **Power feature** — keep secondary, not onboarding |
| Cron/skills from iOS LLM | **3–6 mo** — see cron-bridge plan |
