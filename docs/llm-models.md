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

Three live serving postures + a lapse / archive state. No Free tier — Trial
is the funnel surface, Pro and Ultimate are the revenue surfaces.

Billing is RevenueCat + Apple StoreKit 2. See spec
`docs/superpowers/specs/2026-05-10-billing-tiers-revenuecat-design.md`.

| Tier | What user pays | What they get | Routing |
|---|---|---|---|
| **Trial** (14 d) | $0 with payment on file via Apple IAP, auto-converts to Pro at T+14 unless cancelled | Same as Pro for 14 days | Same as Pro |
| **Pro** | $14.99 / mo (placeholder) | Built-in skills, frontier chat (Sonnet 4.6), DeepSeek/Gemini Flash backbone for skill cron work, 10 M Mtok/mo cap, single device | `low` → Gemini Flash / Together DeepSeek. `medium` → Sonnet 4.6 → Gemini 2.5 Pro. `high` → Sonnet 4.6 → Opus 4.7 (capped). |
| **Ultimate** | $29.99 / mo (placeholder) | All Pro + Opus 4.7 / GPT-5 on every call, user-authored vault skills, on-device MLX (when v2 ships), ContextRouter on, BYO API key, no Mtok cap (per-call budget guard only), priority APNS routing | Full provider matrix, no cap-driven degrade. |
| **Lapsed** | — | Read-only vault + export. 90 d grace before cold archive. | No routing — every gated endpoint returns 402. |
| **Archived** | — | Vault in cold storage, retrievable via support up to 365 d post-lapse. After 365 d, GDPR hard-delete. | No routing. |

Entitlement enforcement uses an env feature flag
(`billing.enforcementEnabled`, default `false`). Flipped to `true` only when
every production ticket has shipped — pre-launch runbook step.

`tier_override` column on `users` lets ops grant Pro/Ultimate to TestFlight
users, internal team, and support cases regardless of RevenueCat state.

## 2. Provider matrix

Authoritative list. Every entry maps to one `ProviderConfig` in
`ProviderRegistry`. Costs are illustrative as of 2026-05; refresh quarterly.

| Provider | Kind | Models we use | $/Mtok in | $/Mtok out | Region (jurisdiction) | CN-weight? | Tier eligibility |
|---|---|---|---|---|---|---|---|
| **Anthropic** | `.anthropicMessages` | Sonnet 4.6, Opus 4.7, Haiku 4.5 | $3 / $15 / $0.80 | $15 / $75 / $4 | US | No | Pro (Sonnet/Haiku), Ultimate (Opus) |
| **OpenAI** | `.openAIChat` | GPT-5, GPT-5-mini | $5 / $0.50 | $20 / $2 | US | No | Ultimate (GPT-5), Pro fallback (mini) |
| **Google Gemini** | `.geminiContents` | Gemini 2.5 Pro, Gemini 2.5 Flash | $2 / $0.10 | $10 / $0.40 | US | No | Pro+ (Pro), Pro+ (Flash for low-capability) |
| **Together** | `.openAICompatible` | DeepSeek-V3.2, Qwen3-Coder, Kimi-K2 | $0.27 / $0.50 / $0.50 | $1.10 / $2 / $2 | US | Yes (weights), No (host) | Pro+ (skill cron backbone) |
| **Groq** | `.openAICompatible` | Kimi-K2, Llama 4 70B | $0.50 / $0.30 | $2 / $0.40 | US | Yes / No | Pro+ fallback |
| **Fireworks** | `.openAICompatible` | DeepSeek-V3.2, Qwen3 | $0.30 / $0.50 | $1.20 / $1.50 | US | Yes (weights), No (host) | Pro+ fallback |
| **DeepSeek-direct** | `.openAICompatible` | DeepSeek-V3.2, DeepSeek-R1 | $0.10 / $0.55 | $0.40 / $2.20 | CN | Yes (weights + host) | Disabled by default — only for users with `privacy_no_cn_origin=false` AND opt-in `prefer_lowest_cost=true` |
| **Hermes gateway** *(legacy)* | `.hermesGateway` | hermes-3 | n/a | n/a | self-hosted | n/a | Dev-only; retired once routing ships in prod |

Notes:
- "CN-weight" = the *model's training jurisdiction*, not the *host's*. DeepSeek-V3.2 is CN-trained even when served by Together (US-hosted).
- Groq Kimi-K2 is CN-weight; Groq Llama is not.
- "Tier eligibility" is enforced by `ModelRouter`, not the provider.

## 3. Capability tiers

Every Hermes call (skill, query, memo, chat) declares a *capability* level.
The router uses capability + tier + privacy to pick the model.

| Capability | What it means | Use cases | Default model (Pro) | Default model (Ultimate) |
|---|---|---|---|---|
| `low` | Cheap reasoning. ~8K context. Quick tool dispatch. | `daily-brief`, `capture-enrich`, ContextRouter selection step | Gemini Flash → Together DeepSeek | Gemini Flash → Sonnet 4.6 |
| `medium` | Balanced. ~64K context. Multi-turn agent loops, light synthesis. | `kb-compile`, `weekly-memo`, `/v1/query`, `/v1/memos` | Sonnet 4.6 → Gemini 2.5 Pro | Sonnet 4.6 → Opus 4.7 → GPT-5 |
| `high` | Frontier reasoning. Long context (≥256K). Complex agentic flows. | `health-correlate`, ContextRouter expansion (Ultimate-only), future power-user skills | Sonnet 4.6 → Opus 4.7 (Pro cap-degrades on hit) | Opus 4.7 → GPT-5 → Sonnet 4.6 |

Skills declare capability in their SKILL.md frontmatter:
```yaml
metadata:
  capability: medium
```

User chat (`/v1/chat/completions`) is `medium` by default; can be overridden
per-request with `model:` field for Ultimate users.

Trial users see Pro routing for the trial period. Lapsed / archived users
get 402 — no routing happens.

## 4. Privacy posture

Two user-level toggles control routing privacy.

### `users.privacy_no_cn_origin` (default `false`)

When `true`, `ModelRouter` excludes any model where the *weights* originate
in CN — DeepSeek, Qwen, Kimi — *even if hosted by a US provider*. The
weight provenance is the concern, not the inference data plane.

Trade-off: Pro users with this toggle get more expensive routing
(Gemini Flash → GPT-5-mini fallback instead of DeepSeek). Documented
in iOS Settings UI.

The toggle is gated to **Pro+** (the privacy posture toggles are part
of the privacy section of the Settings UI, which only renders for
entitled users).

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

The Pro tier is the largest financial risk. A misbehaving agent loop on
Sonnet 4.6 can burn $5+ per session, and at $14.99 / mo we have ~$10
gross-margin headroom per user-month after Apple's 15-30% cut.

Three layers of defense.

### Monthly Mtok cap (Pro tier only)

`UsageMeter` (HER-175) increments after every LLM response with the
provider's reported token counts. When the user's running 30-day total
`(mtok_in + mtok_out)` exceeds `usage.proMtokMonthly` (default 10 M):

- `medium` and `high` requests *degrade* to `low` automatically; response gets header `X-LV-Degraded: cap_reached`.
- Once even `low` would push past `usage.proMtokMonthlyHardStop` (default 30 M), the call returns 429 with `Retry-After: <hours_until_next_billing_period>`.

Ultimate tier has no monthly cap (per-call budget guard still applies).
Trial users see Pro caps. Lapsed users return 402 before any cap check
runs.

### Per-skill budget

Each skill run is bounded by `usage.perSkillMtokDaily` (default 0.2 M)
*regardless of tier*. Prevents a runaway agent loop in a single skill from
draining the user's whole budget. When the skill exceeds its budget mid-run,
the loop terminates with a `skill_budget_exceeded` status in
`skill_run_log`.

### Trial cost projection

Trial users get Pro features for 14 days with no card-charge yet. Cost
modeling:

- Median trial user: ~3 M Mtok over 14 days at Together DeepSeek + Sonnet mix
- Cost: ~$1.50 / trial-user
- Break-even at ~10 % conversion to Pro ($14.99 × 12 mo × 0.85 Apple cut = $153 LTV per acquired Pro user)

Conversion-rate trigger: if trial → Pro conversion drops below 8 % over a
month, tighten the trial scope (e.g. switch `health-correlate` from `high`
to `medium` during trial) before raising prices.

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
Daily ops includes `tier` join to attribute cost per tier:
```sql
SELECT u.tier, m.model, SUM(m.mtok_in + m.mtok_out) AS total
FROM usage_meter m JOIN users u USING (tenant_id)
WHERE m.day >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY u.tier, m.model;
```

When margin compresses (Pro user costs > revenue per Pro user × N weeks),
options in order of preference:

1. Lower default capability (`medium` → `low`) for non-essential skills
2. Reduce `usage.proMtokMonthly` (10 M → 5 M)
3. Add cheaper provider (next-cheapest open-weights host)
4. Re-platform on self-hosted vLLM (HER-160 unblocks this)
5. Raise Pro price (Apple lets you grandfather existing subs)
