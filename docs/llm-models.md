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

Three live serving postures + a lapse / archive state. No Free *tier* — Trial
is the funnel surface, Pro and Ultimate are the revenue surfaces. There is a
free **lane**, which is a routing state rather than a tier; see §4a.

### The routing law

> **Paying (`pro`/`ultimate`, including `tier_override`) or BYOK-with-a-real-key
> ⇒ the user's own choice is honoured. Everyone else ⇒ the free lane,
> non-overridable.**

Stated once, in code, in `FreeLanePolicy.evaluate`. Enforced at **route time
only**: `PUT /v1/me/preferences/llm` and the router-profile writes persist
whatever the user asked for and never reject it, so a stored preference takes
effect the instant they upgrade or add a key. The read surfaces canonicalise
instead — a user on the forced lane is reported as managed
(`"LuminaVault Brain · Auto"`), which is true, and keeps the concrete model id
off the wire per §5.

Trial counts as paying (card on file). Archived is untouched: it is read-only
and `EntitlementMiddleware` 402s before routing happens.

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
| **OpenRouter** | `.openAICompatible` | Managed default (`HERMES_DEFAULT_MANAGED_MODEL`, currently `deepseek/deepseek-v4-flash`); free lane leg 1 | varies | varies | US | No | All tiers (managed default); free lane |
| **NVIDIA NIM** | `.openAICompatible` | Nemotron 3 Nano / Super / Ultra; free lane leg 2 | $0.05 / $0.085 / $0.60 | $0.20 / $0.40 / $3.60 | US | No | BYOK any tier; free lane |
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

## 4a. Free fallback lane

The forced route for anyone who is neither paying nor bringing a key, and the
emergency route when platform managed inference is unavailable. Not a tier: no
`UserTier` case, no migration, no entitlement change. `FREELANE_ENABLED=false`
removes it entirely and restores pre-lane routing exactly.

### Legs, in failover order

| # | Leg | Provider | Default model | Context | Why it's free |
|---|---|---|---|---|---|
| 1 | `openRouterFree` | platform OpenRouter key | `nvidia/nemotron-3-ultra-550b-a55b:free` | 1,000,000 | zero-rated slug — cannot bill us |
| 2 | `nvidiaDirect` | platform NVIDIA NIM key | `nvidia/nemotron-3-super-120b-a12b` | 1,000,000 | finite signup credits |

**The two legs are free for different reasons, and only one is free by
construction.** The OpenRouter leg is a `:free` slug: zero-rated, no balance
consumed, so no amount of use can bill us. The NIM leg is a *normal, billable*
model id — the same one the paid provider matrix in §2 prices at $0.085 / $0.40
per Mtok. It is free only while NVIDIA's signup credits last; **once they are
exhausted, NVIDIA bills at list price.**

That makes `freelane.nvidiaDailyRequests` a genuine spend ceiling, not just a
rate limit. Size it against the credit balance, and treat sustained leg-2 traffic
as a signal to buy OpenRouter credit (which raises leg 1's account-wide ceiling
from 50/day to 1000/day) rather than to raise the NIM cap.

OpenRouter goes first for the same reason: it is the renewable resource. Spend
that before the finite one.

The two legs carry **different model ids on purpose**. `:free` is an OpenRouter
routing directive, not part of the model id — sending it to
`integrate.api.nvidia.com` 404s the model. `FreeLaneCatalogTests` asserts this.

Every free slug must clear Hermes Agent's hard **≥64K context floor** on both the
primary model and `auxiliary.compression`, or Hermes refuses to start the turn.
Also asserted in `FreeLaneCatalogTests`.

Free slugs are deliberately **absent from `RouterModelCatalog`**.
`AvailableModelPoolBuilder` expands every catalogue entry into the Auto pool for
each usable provider, so a $0 entry wins cost-first scoring and hands a *paying*
user a rate-limited free model while burning the platform's account-wide free
allowance. That bug shipped once; a test now guards against it.

### Metering

OpenRouter's free-model limits are **account-wide, not per user**: 20 req/min,
and 50 req/day until $10 of credit has ever been purchased (1000/day after). So
the lane needs two ceilings — a per-user daily grace so one user cannot starve
everyone, and a per-leg platform ceiling that keeps us under the provider limit.

`FreeLaneGate` stores both in `workflow_spend_buckets` (`M109_CerberusStudio`)
under a `freelane:` scope-key namespace, reusing its atomic
`UPDATE … WHERE spent + 1 <= limit RETURNING` idiom — race-free, so N concurrent
claims against a limit of M grant exactly M. **The unit stored in
`spent_usd_micros` is REQUESTS, not micro-dollars**; a free request costs nothing,
so counting money would only ever store zero. No migration was needed.

The gate fails **open** if the SQL driver is unavailable: a metering outage must
not take chat down for every non-paying user at once, and the lane it grants
costs $0, so the blast radius is provider rate limits rather than money.

Per-minute limits are not metered (`period_start` is a DATE). They surface as
upstream 429s, which `ProviderErrorClassifier` marks recoverable, so the
transport fails over to the next route — correct, and free.

The OpenRouter leg carries **two** `:free` slugs, tried in order, and they share
one `FreeLaneGate` counter on purpose. OpenRouter's free allowance is
account-wide across every `:free` slug, not per model, so a second slug buys
resilience against one model being down or per-minute throttled — it does not
buy capacity. Giving it its own `Leg` would double-spend the same allowance.

### Config

| Key | Env | Default |
|---|---|---|
| `freelane.enabled` | `FREELANE_ENABLED` | `true` |
| `freelane.openRouterModel` | `FREELANE_OPEN_ROUTER_MODEL` | `z-ai/glm-5.2:free` |
| `freelane.openRouterSecondaryModel` | `FREELANE_OPEN_ROUTER_SECONDARY_MODEL` | `nvidia/nemotron-3-ultra-550b-a55b:free` |
| `freelane.nvidiaModel` | `FREELANE_NVIDIA_MODEL` | `nvidia/nemotron-3-super-120b-a12b` |
| `freelane.perUserDailyRequests` | `FREELANE_PER_USER_DAILY_REQUESTS` | `20` |
| `freelane.openRouterDailyRequests` | `FREELANE_OPEN_ROUTER_DAILY_REQUESTS` | `45` |
| `freelane.nvidiaDailyRequests` | `FREELANE_NVIDIA_DAILY_REQUESTS` | `900` |

Buying $10 of OpenRouter credit once lifts the account ceiling from 50/day to
1000/day. It is the cheapest capacity purchase available — do it before launch
and raise `freelane.openRouterDailyRequests` to ~900.

### Exhaustion

`429` + `Retry-After`, body
`{"error":{"code":"free_lane_exhausted","message":…,"cta":["upgrade","add_key"],"retryAfterSeconds":…}}`.
Same envelope shape as `byok_keys_required`. The message names no model or
provider — the lane is managed mode, so model identity is hidden (§5), and an
error string is just another place it can leak.

### Disclosure

The lane sets `mode: .managed` in its decision metadata, so every existing scrub
applies unchanged: SSE `routing` / `usage` / `fallback` frames, the
`systemPromptGuard` injection, and the analytics labels. This is also why the
lane must never be modelled as a BYOK mode — BYOK is the disclosed mode, and it
would both reveal the slug and send the adapters looking for a tenant key.

### Legacy router

Under `CERBERUS_EXECUTION_MODE != "active"`, `TableModelRouter` serves the same
two legs but **without** the gate — there is no decision metadata on that path to
carry an exhaustion error. The structural cost fix still holds because neither leg
is billable. That router is the documented rollback lane, not a supported mode.

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

## 6. BYO API key (LLM brain mode)

Shipped as `LLMBrainMode.byok` on `/v1/me/preferences/llm` and Cerberus router
profiles. Any chat-capable tier may use LLM BYOK; Ultimate-only billing applies
to `privacyBYOKey` (privacy settings), not LLM brain mode.

- Credentials: `user_provider_credentials` table, encrypted at rest; managed via
  `PUT /v1/me/providers/{provider}`.
- Routing: user keys take precedence; when BYOK is active and no keys exist, chat
  fails closed with `403 byok_keys_required` (never debits the platform OpenRouter key).
- Clients should parse `{ "error": { "code", "message", "cta" } }` and offer
  Settings / switch-to-managed recovery.

**Where fail-closed is enforced.** In all four credential resolvers —
`OpenAICompatibleAdapter`, `AnthropicAdapter`, `GeminiContentsAdapter`, and
`OllamaAdapter` — not only in Cerberus. Cerberus' own guard is bypassed whenever
`CERBERUS_EXECUTION_MODE != "active"`, so relying on it alone left every
non-Cerberus chat path spending the platform key for BYOK users who had no key.
The adapters throw on four paths: no credential row, a row with a nil/empty key,
an unreadable credential (decrypt failure or missing SecretBox), and a
BYOK-declared request with no resolvable tenant.

`RoutedLLMTransport` rethrows `BYOKKeysRequiredError` instead of advancing to the
next candidate — every remaining candidate is missing the same credential, and
failing over would convert the precise 403 into a generic `upstream_error`.

Who pays is carried on `RouteDecision.credentialMode`, published by both the
Cerberus and legacy routers and preserved across the forced-route ("Ask another
model") rebuild. `nil` means no caller declared an intent — internal and cron
work with no user attached — and keeps managed semantics, because those calls
genuinely are platform-funded.

**Non-entitled BYOK users no longer hit this error.** A lapsed user who selected
BYOK and has no key gets the free lane (§4a) instead of a 403 dead end.

## 7. Cost guardrails

The Pro tier is the largest financial risk. A misbehaving agent loop on
Sonnet 4.6 can burn $5+ per session, and at $14.99 / mo we have ~$10
gross-margin headroom per user-month after Apple's 15-30% cut.

Five layers, listed with the config keys that actually exist. Earlier revisions
of this section documented `usage.proMtokMonthly` and
`usage.proMtokMonthlyHardStop`, and a header `X-LV-Degraded` — none of those are
real. Check against `App+build.swift` before adding a knob here.

| Layer | Where | Scope | Notes |
|---|---|---|---|
| Free lane | `FreeLanePolicy` + `FreeLaneGate` | non-entitled users, and everyone during a platform outage | The floor. Costs $0 by construction. See §4a. |
| Daily token cap | `UsageMeterService` | trial | `usage.freeMtokDaily` (1.0), `usage.perSkillMtokDaily` (0.2), degrade model `usage.degradeModel`. Degrade header is `X-LuminaVault-Degraded`. |
| Daily USD cap | `CostLedgerService` | managed calls | `managedDailyCapUsdMicros` |
| Monthly reservation | `RouterTelemetryService` | per profile budget | soft limit flips the router to cost-first scoring |
| Studio spend buckets | `WorkflowSpendService` | workflow runs | per-run/day/month, hardcoded per tier; globals via `CERBERUS_STUDIO_GLOBAL_*_USD_MICROS` |

**Known gap:** `UsageMeterService.checkBudget` is called from `POST /v1/chat`
only. The app's real chat surface is SSE, which does not go through it, so the
daily token cap does not currently bound the main path. The free lane and the
USD-denominated layers do.

Lapsed users are `.allow` at the meter — denying there would 429 them before the
free lane is reachable. Archived stays `.deny`. Ultimate has no monthly token
cap (per-call budget guard still applies); trial sees the daily cap above.

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
