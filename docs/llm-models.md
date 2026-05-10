# LuminaVaultServer — LLM Model Strategy

How LuminaVault picks models for every Hermes call: which providers, what
each tier gets, the privacy posture, and the rules for adding more.

This is a living document. The provider matrix in §2 is authoritative —
when we add a provider, both this doc and `ProviderRegistry` get updated
in the same PR.

Implementation references:
- Routing layer lives at `Sources/App/LLM/Routing/` (HER-161..HER-166).
- Tier + privacy column on `users` table (HER-174).
- Per-user usage caps in `UsageMeterService` (HER-175).

## 1. Tiered hosting

Three serving postures. Today only Free + Pro ship; BYO is v2.

| Tier | What user pays | What they get | Routing |
|---|---|---|---|
| **Free** | $0 | Cheap-tier inference, daily Mtok cap, 5 built-in skills. No frontier models. | `low` / `medium` capability → Gemini Flash, DeepSeek-V3.2 (Together / Groq), Kimi-K2 (Groq). `high` capability degrades to `medium` once daily cap hit. |
| **Pro** | $X / mo via Stripe | Frontier models on-demand, no daily cap (per-request budget guard still applies), context-routing opt-in, vault-authored skills. | Anthropic (Sonnet 4.6 / Opus 4.7 / Haiku 4.5), OpenAI (GPT-5 / GPT-5-mini), Gemini 2.5 Pro, full fallback chain. |
| **BYO** *(v2)* | $0 hosting + their own provider bill | User pastes their Anthropic / OpenAI / DeepSeek / Together / Groq key in Settings; we proxy to it. | User key is tried *first*; falls back to hosted tier if their key returns 401/429. |

The Free tier is the marketing surface — "personal LLM second brain you
can use without an API key." The Pro tier is the revenue surface. BYO is
a power-user fallback for self-hosters and privacy maxis.

## 2. Provider matrix

Authoritative list. Every entry maps to one `ProviderConfig` in
`ProviderRegistry`. Costs are illustrative as of 2026-05; refresh quarterly.

| Provider | Kind | Models we use | $/Mtok in | $/Mtok out | Region (jurisdiction) | CN-weight? | Tier eligibility |
|---|---|---|---|---|---|---|---|
| **Anthropic** | `.anthropicMessages` | Sonnet 4.6, Opus 4.7, Haiku 4.5 | $3 / $15 / $0.80 | $15 / $75 / $4 | US | No | Pro |
| **OpenAI** | `.openAIChat` | GPT-5, GPT-5-mini | $5 / $0.50 | $20 / $2 | US | No | Pro |
| **Google Gemini** | `.geminiContents` | Gemini 2.5 Pro, Gemini 2.5 Flash | $2 / $0.10 | $10 / $0.40 | US | No | Pro (Pro), Free (Flash) |
| **Together** | `.openAICompatible` | DeepSeek-V3.2, Qwen3-Coder, Kimi-K2 | $0.27 / $0.50 / $0.50 | $1.10 / $2 / $2 | US | Yes (weights), No (host) | Free, Pro fallback |
| **Groq** | `.openAICompatible` | Kimi-K2, Llama 4 70B | $0.50 / $0.30 | $2 / $0.40 | US | Yes / No | Free, Pro fallback |
| **Fireworks** | `.openAICompatible` | DeepSeek-V3.2, Qwen3 | $0.30 / $0.50 | $1.20 / $1.50 | US | Yes (weights), No (host) | Free, Pro fallback |
| **DeepSeek-direct** | `.openAICompatible` | DeepSeek-V3.2, DeepSeek-R1 | $0.10 / $0.55 | $0.40 / $2.20 | CN | Yes (weights + host) | Disabled by default — only for users with `privacy_no_cn_origin=false` AND opt-in `prefer_lowest_cost=true` |
| **Hermes gateway** *(legacy)* | `.hermesGateway` | hermes-3 | n/a | n/a | self-hosted | n/a | Dev-only; retired once routing ships in prod |

Notes:
- "CN-weight" = the *model's training jurisdiction*, not the *host's*. DeepSeek-V3.2 is CN-trained even when served by Together (US-hosted).
- Groq Kimi-K2 is CN-weight; Groq Llama is not.
- "Tier eligibility" is enforced by `ModelRouter`, not the provider.

## 3. Capability tiers

Every Hermes call (skill, query, memo, chat) declares a *capability* level.
The router uses capability + tier + privacy to pick the model.

| Capability | What it means | Use cases | Default model (Free) | Default model (Pro) |
|---|---|---|---|---|
| `low` | Cheap reasoning. ~8K context. Quick tool dispatch. | `daily-brief`, `capture-enrich`, ContextRouter selection step | Gemini Flash → Together DeepSeek | Gemini Flash → Sonnet 4.6 |
| `medium` | Balanced. ~64K context. Multi-turn agent loops, light synthesis. | `kb-compile`, `weekly-memo`, `/v1/query`, `/v1/memos` | Together DeepSeek-V3.2 → Groq Kimi-K2 | Sonnet 4.6 → Gemini 2.5 Pro |
| `high` | Frontier reasoning. Long context (≥256K). Complex agentic flows. | `health-correlate`, ContextRouter expansion (Pro opt-in), future power-user skills | (degrades to `medium` once Free daily cap hit) | Sonnet 4.6 → Opus 4.7 → GPT-5 |

Skills declare capability in their SKILL.md frontmatter:
```yaml
metadata:
  capability: medium
```

User chat (`/v1/chat/completions`) is `medium` by default; can be overridden
per-request with `model:` field for Pro users.

## 4. Privacy posture

Two user-level toggles control routing privacy.

### `users.privacy_no_cn_origin` (default `false`)

When `true`, `ModelRouter` excludes any model where the *weights* originate
in CN — DeepSeek, Qwen, Kimi — *even if hosted by a US provider*. The
weight provenance is the concern, not the inference data plane.

Trade-off: Free users with this toggle get more expensive routing
(Gemini Flash → GPT-5-mini fallback instead of DeepSeek). Documented
in iOS Settings UI.

### `users.privacy_prefer_lowest_cost` (default `false`)

When `true` AND `privacy_no_cn_origin=false`, the user opts into routing
via `DeepSeek-direct` (Chinese-hosted) for the cheapest possible inference.
Off by default because the inference data plane is in CN jurisdiction.

### Jurisdiction map

| Origin of weights | Origin of inference host | What flag toggles this |
|---|---|---|
| Western (Anthropic / OpenAI / Google / Llama) | US | always allowed |
| CN (DeepSeek / Qwen / Kimi) | US (Together / Groq / Fireworks / DeepInfra) | excluded by `privacy_no_cn_origin=true` |
| CN (DeepSeek) | CN (api.deepseek.com) | gated by `privacy_prefer_lowest_cost=true` AND `privacy_no_cn_origin=false` |

`PUT /v1/me/privacy` flips these toggles (HER-176). Effect is immediate —
next request uses new route.

## 5. Adding a provider

Five-step playbook. Update both code + this doc in the same PR.

1. **Env vars** — add `<PROVIDER>_API_KEY` and `<PROVIDER>_BASE_URL` to
   `docker-compose.yml` and `.env.example`. Key absence = provider disabled
   (do not crash boot).
2. **Provider config** — append a `ProviderConfig` literal to
   `ProviderRegistry.bootSeed()` with `name`, `kind`, `models[]`, `region`.
   Pick the correct adapter `kind`:
   - OpenAI-shape compatible → `.openAICompatible`
   - Anthropic Messages → `.anthropicMessages`
   - Gemini contents → `.geminiContents`
   - Custom shape → write a new adapter (rare)
3. **Routing rules** — update `ModelRouter.pick()` rule table. New providers
   typically join the *fallback* chain first (e.g. add Groq as fallback for
   `free+medium`), promoted to *primary* only after a week of error-rate
   data shows them stable.
4. **Smoke test** — add a fixture under `Tests/AppTests/LLM/RoutingTests.swift`
   calling the provider with `model: "ping"` payload, asserting 200.
   Skip-marker if API key not set in test env.
5. **Doc update** — add row to §2 Provider matrix above. Update §3 if the
   provider lands in a default for any tier.

## 6. BYO API key (v2)

Not in v1. Sketch for the future:

- New table `user_api_keys (tenant_id UUID FK, provider TEXT, encrypted_key BYTEA, created_at, last_used_at)` — encrypted at rest with a per-server symmetric key (AWS KMS / HashiCorp Vault).
- iOS Settings → Connections sheet: "Use my Anthropic key" → paste → POST `/v1/me/api-keys`.
- `ProviderRegistry.providersFor(tenantID)` merges per-user keys with platform defaults; per-user takes precedence.
- Routing: user-key call attempted first. On 401 / quota error, fall back to platform default with a `WARN` log.
- Privacy bonus: BYO keys land in the *user's* provider account, not ours — strongest privacy story for power users.

## 7. Cost guardrails

The Free tier is the largest financial risk. A misbehaving agent loop on
Sonnet 4.6 can burn $5+ per session. Two layers of defense.

### Daily Mtok cap (Free tier only)

`UsageMeter` (HER-175) increments after every LLM response with the
provider's reported token counts. When today's `(mtok_in + mtok_out)`
exceeds `usage.freeMtokDaily` (default 1.0M):

- `medium` and `high` requests *degrade* to `low` automatically; response gets header `X-LV-Degraded: cap_reached`.
- Once even `low` would push past `usage.freeMtokDailyHardStop` (default 5.0M), the call returns 429 with `Retry-After: <hours_until_midnight_user_local>`.

### Per-skill budget

Each skill run is bounded by `usage.perSkillMtokDaily` (default 0.2M)
*regardless of tier*. Prevents a runaway agent loop in a single skill from
draining the user's whole budget. When the skill exceeds its budget mid-run,
the loop terminates with a `skill_budget_exceeded` status in
`skill_run_log`.

### Cost dashboard

Daily op query:
```sql
SELECT model,
       SUM(mtok_in)   AS mtok_in,
       SUM(mtok_out)  AS mtok_out
FROM usage_meter
WHERE day = CURRENT_DATE
GROUP BY model
ORDER BY (SUM(mtok_in) + SUM(mtok_out)) DESC;
```

Cost per provider: cross-join with the `$/Mtok` table from §2.

When margin compresses (Free user costs > revenue per Free user × N weeks),
options in order of preference:

1. Lower default capability (`medium` → `low`) for non-essential skills
2. Reduce `usage.freeMtokDaily` (1.0M → 0.5M)
3. Add cheaper provider (next-cheapest open-weights host)
4. Re-platform on self-hosted vLLM (HER-160 unblocks this)
