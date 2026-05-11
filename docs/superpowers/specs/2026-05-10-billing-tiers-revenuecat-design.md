# Billing, Tiers, and RevenueCat Paywall — Design

**Status:** Approved 2026-05-10
**Supersedes:** HER-174 Free+Pro Stripe tier design in `gentle-humming-pumpkin.md` (Commercial cluster) — kept open until replaced by tickets filed from this spec.
**Owner:** Backend (Hummingbird) + iOS (Client)

## Context

LuminaVault's `docs/llm-models.md` originally specified a tiered hosted
model with **Free + Pro** tiers backed by Stripe. Math doesn't work:

- A moderately-active Free user runs all 5 built-in skills daily, captures ~5
  items/day, chats ~10 msgs/day. That's ~5 M Mtok / month.
- At Together DeepSeek-V3.2 prices ($0.27 in / $1.10 out) that's ~$3 / user / month.
- 1 000 Free users × $3 = $3 K / month subsidy with ~5 % typical conversion =
  $20-40 / acquired Pro user that we don't recoup until month 2 + of LTV.
- The Karpathy-second-brain market is small but high-LTV. Mass-market freemium
  funnel is not the win condition; premium positioning is.

This spec replaces the Free + Pro Stripe design with **Trial 14 d → Pro →
Ultimate** backed by **RevenueCat + Apple StoreKit 2**.

User-stated constraints:

1. No Free tier.
2. RevenueCat is the billing rails. iOS-first; web/Android later.
3. Build the entire billing + entitlement + paywall stack now, but **do not
   enforce gating on endpoints until every production ticket has shipped.** A
   single env flag (`billing.enforcementEnabled`) toggles enforcement.

## Tiers

| Tier | Price (USD) | Apple product ID | Surface |
|---|---|---|---|
| **Trial** | $0 with payment method on file via Apple IAP, auto-converts at T+14 unless cancelled | (introductory offer on `pro_monthly`) | Full Pro features for 14 days |
| **Pro** | $14.99 / mo | `lv_pro_monthly_1499` | 5 built-in skills, DeepSeek/Gemini Flash backbone, Sonnet 4.6 for chat, 10 M Mtok/mo cap, single device |
| **Ultimate** | $29.99 / mo | `lv_ultimate_monthly_2999` | All Pro + Opus 4.7 / GPT-5 / Sonnet on every call, user-authored vault skills, on-device MLX (when v2 ships), ContextRouter on, BYO API key, no Mtok cap (per-call budget guard only), priority APNS routing |
| **Lapsed** | — | — | Read-only vault + export. 90 d grace → cold archive. 365 d → GDPR hard-delete. Re-sub reactivates instantly. |
| **Archived** | — | — | Vault in cold storage, retrievable via support for up to 365 d post-lapse. After 365 d, hard delete. |

Pricing is product-call placeholder; spec relies on these anchors for
$/Mtok math and trial-cost projections.

## Architecture

**RevenueCat is billing source-of-truth. Server is entitlement
source-of-truth.** iOS uses the RevenueCat SDK for paywall display and IAP
purchase flow; server reads `users.tier` for every authenticated request and
enforces capability checks via middleware.

```
iOS → StoreKit 2 → Apple IAP → RevenueCat
                                  │
                                  └─ webhook ─→ POST /v1/billing/revenuecat-webhook
                                                  │
                                                  └─ HMAC-validated, idempotent on event.id
                                                  └─ updates users.tier + tier_expires_at

iOS → GET /v1/me        → server reads users.tier → entitlement summary in response
iOS → other endpoints   → EntitlementMiddleware (server)
                            └─ if billing.enforcementEnabled=false: pass through
                            └─ if billing.enforcementEnabled=true and tier insufficient:
                                  return 402 + {paywall: true, paywallId: "..."}
                            iOS reacts → RevenueCat SDK presents PaywallView
```

### Why server-authoritative entitlement

- Client-only checks are bypassable (modified app, intercepting proxy). User
  data is sensitive; subscription enforcement cannot live on the client.
- RC SDK reports same answer client-side for UI hints, but the server is the
  one that decides whether `/v1/chat/completions` actually responds.
- RC publishes a server-side REST API. Server can optionally double-check
  entitlement against RC at request time. We don't: webhook is already source
  of truth and adds 0 latency per request vs. ~200 ms per RC API call.

## Components

### Server (Hummingbird)

| File | Purpose |
|---|---|
| `Sources/App/Billing/RevenueCatWebhookController.swift` | Receives `POST /v1/billing/revenuecat-webhook`. HMAC-validates against `REVENUECAT_WEBHOOK_SECRET`. Dispatches RC event types: `INITIAL_PURCHASE`, `RENEWAL`, `CANCELLATION`, `EXPIRATION`, `PRODUCT_CHANGE`, `BILLING_ISSUE`, `SUBSCRIBER_ALIAS`. Updates `users.tier` + `tier_expires_at` + `revenuecat_user_id`. Idempotent on `event.id`. |
| `Sources/App/Billing/EntitlementMiddleware.swift` | Hummingbird middleware. Reads `ctx.identity.tier` + `tier_override`. Matches against route's declared required capability. Returns 402 with paywall hint when insufficient. No-ops when `billing.enforcementEnabled=false`. |
| `Sources/App/Billing/EntitlementChecker.swift` | Pure function `func entitled(tier: UserTier, override: TierOverride, for capability: Capability) -> Bool`. Has no Hummingbird deps so unit-testable in isolation. |
| `Sources/App/Billing/RevenueCatClient.swift` | Thin URLSession wrapper around RevenueCat REST API. Used by ops admin endpoints (re-sync a single user, etc). Not used per-request. |
| `Sources/App/Migrations/M21_AddTierFields.swift` | Extends `users` table: alter `tier` enum, add `tier_expires_at`, `tier_override`, `revenuecat_user_id`. |
| `Sources/App/Skills/LapseArchiverSkill.swift` (or built-in skill via `Resources/Skills/lapse-archiver/SKILL.md`) | Cron-driven nightly. Lapsed > 90 d → `tier='archived'` + move vault to cold storage. Archived > 365 d → hard delete row + S3/disk path. |

### iOS (Client)

| Component | Purpose |
|---|---|
| `BillingService.swift` (new) | Wraps `RevenueCat` SDK. Exposes `Entitlement` enum to SwiftUI as `@Observable`. Handles `Purchases.configure(apiKey:)` at app launch. Calls `Purchases.shared.logIn(serverUserID)` after server-side sign-up so RC and server share identity. |
| `PaywallView.swift` | RC SDK provides `PaywallView()` SwiftUI component bound to a placement ID. Sci-fi-themed via `LVThemeManager` color tokens. |
| `EntitlementGate.swift` | View modifier `.requiresTier(.pro)` that wraps a view; presents PaywallView when server returns 402 or local cache says lapsed. |
| `BillingClient.swift` | HTTP client for `GET /v1/me/billing` (returns current entitlement summary) and `POST /v1/me/billing/refresh` (force-sync with RC). |

### Schema (M21 migration)

```sql
ALTER TABLE users
    ALTER COLUMN tier TYPE TEXT,
    ALTER COLUMN tier SET DEFAULT 'trial';

-- normalize existing rows (M17 introduced 'free'/'pro'; both go to 'trial' or 'pro')
UPDATE users SET tier = 'trial' WHERE tier = 'free';
UPDATE users SET tier = 'pro'   WHERE tier = 'pro';

ALTER TABLE users
    ADD CONSTRAINT users_tier_check
    CHECK (tier IN ('trial', 'pro', 'ultimate', 'lapsed', 'archived'));

ALTER TABLE users
    ADD COLUMN tier_expires_at        TIMESTAMPTZ NULL,
    ADD COLUMN tier_override          TEXT        DEFAULT 'none'
        CHECK (tier_override IN ('none', 'pro', 'ultimate')),
    ADD COLUMN revenuecat_user_id     TEXT        NULL UNIQUE;

CREATE INDEX users_tier_expires_idx ON users(tier_expires_at)
    WHERE tier_expires_at IS NOT NULL;
```

`tier_override` is the ops bypass — set to `ultimate` for TestFlight users,
internal team, support cases. Always wins over RC-driven `tier`.

## Gating matrix

User-facing rule: **always-open endpoints work without any subscription;
gated endpoints work during Trial/Pro/Ultimate; lapsed users can still read
and export their vault.**

| Endpoint | Always open | Required tier when enforced |
|---|---|---|
| `POST /v1/auth/*` (register, login, refresh, OAuth) | ✓ | — |
| `GET /v1/me`, `GET /v1/me/billing` | ✓ | — |
| `GET /v1/vault/*` (read), `GET /v1/vault/export.zip` | ✓ even when lapsed | — |
| `POST /v1/capture/*` (Safari, photo, voice, manual) | ✓ during trial | Pro+ |
| `POST /v1/health` (HealthKit ingest) | ✓ during trial | Pro+ |
| `POST /v1/chat/completions` | — | Pro+ |
| `POST /v1/query` | — | Pro+ |
| `POST /v1/memos` | — | Pro+ |
| `POST /v1/skills/{name}/run` (built-in) | — | Pro+ |
| `POST /v1/skills/{name}/run` (vault-authored) | — | Ultimate |
| `POST /v1/kb/compile` | — | Pro+ |
| `PUT /v1/me/privacy` (BYO key, no_cn_origin, context_routing) | — | Ultimate for BYO key; Pro+ for privacy toggles |

## Capability enum

`EntitlementChecker` keys off this enum, not endpoint paths:

```swift
enum Capability: String, Sendable {
    case vaultRead              // always
    case vaultExport            // always
    case capture                // trial+
    case healthIngest           // trial+
    case chat                   // trial+ (trial users get Pro models)
    case memoryQuery            // trial+
    case memoGenerator          // trial+
    case skillBuiltinRun        // trial+
    case skillVaultRun          // ultimate
    case kbCompile              // trial+
    case privacyBYOKey          // ultimate
    case privacyContextRouter   // ultimate
    case mlxOnDevice            // ultimate (v2)
}
```

`func entitled(tier: UserTier, override: TierOverride, for: Capability) -> Bool`
is a flat 5-case switch per tier. Trivial to unit-test exhaustively.

## Data flow

1. **Sign up.** iOS → `POST /v1/auth/register` → server creates User row with
   `tier='trial'`, `tier_expires_at=NOW()+14 d`. iOS receives JWT.
2. **iOS post-signup.** Client calls `Purchases.shared.logIn(<userID>)` to
   tell RevenueCat about this user. RC creates an anonymous subscriber tied
   to `userID`. No purchase yet.
3. **User taps Subscribe (any time during trial).** iOS triggers
   `Purchases.shared.purchase(product:)` for `lv_pro_monthly_1499` or
   `lv_ultimate_monthly_2999`. Apple IAP processes. RC sees the transaction.
   RC fires `INITIAL_PURCHASE` webhook → server flips `users.tier` to
   `pro` or `ultimate`, sets `tier_expires_at` from event payload.
4. **Trial expires without purchase.** Apple does not auto-charge (intro
   offer is one-shot). RC fires `EXPIRATION` event → server flips tier to
   `lapsed`. iOS UI shows paywall on next protected route call.
5. **Renewal.** Each month Apple bills, RC fires `RENEWAL` → server extends
   `tier_expires_at`.
6. **Cancellation / refund.** RC fires `CANCELLATION` with `is_refund=true`
   or expiration date in past → server flips tier to `lapsed`.
7. **Lapse cron.** Nightly `lapse-archiver` skill: `users WHERE tier='lapsed'
   AND tier_expires_at < NOW() - INTERVAL '90 days'` → set `tier='archived'`,
   move vault to cold storage path. Email user.
   `users WHERE tier='archived' AND tier_expires_at < NOW() - INTERVAL '365 days'`
   → hard delete row + delete cold-storage vault dir. GDPR-compliant.
8. **Re-sub after lapse.** User subscribes again from paywall → `INITIAL_PURCHASE` or
   `RENEWAL` webhook → server flips tier back to Pro/Ultimate, restores vault
   from cold storage if archived (single nightly task; user sees "Vault
   restoring..." status for up to 24 h).

## Enforcement flag

`billing.enforcementEnabled` (env var `BILLING_ENFORCEMENT_ENABLED`, default
`false`):

- `false`: `EntitlementMiddleware` is a no-op. Every authenticated user
  effectively has `tier='ultimate'` for the duration of the request.
  Used for dev, beta, TestFlight cohorts, internal team.
- `true`: middleware enforces. Pre-launch checklist gate — flipped only when
  every production ticket has shipped and we're sure no in-flight feature is
  gated wrong.

In addition to the global flag, `tier_override` column on `users` provides
per-user bypass even when enforcement is on. Set via admin endpoint
`PUT /v1/admin/users/{id}/tier-override` (shared-secret gated, off in dev).

## Error handling

| Failure | Response |
|---|---|
| RC webhook arrives with bad HMAC | 401, log + alert (likely abuse) |
| RC webhook event for unknown `revenuecat_user_id` | 200 (idempotent), warn-log (sub-before-signup race) |
| RC webhook duplicate `event.id` | 200 (already-processed), no-op |
| User tier=`lapsed` calls `POST /v1/chat/completions` | 402 `{paywall: true, paywallId: "default"}` |
| User tier=`trial` calls Ultimate-only endpoint | 402 `{paywall: true, paywallId: "ultimate_upsell"}` |
| Trial in grace (Apple billing retry, RC fires `BILLING_ISSUE`) | tier stays Pro/Ultimate, server returns header `X-LV-Billing-Issue: true` so iOS can prompt user to update payment |
| Lapse archiver hits storage backend error | retry per-user next night, do not progress to archived |

## Testing

### Unit tests

- `EntitlementCheckerTests` — every (`tier`, `override`, `Capability`) combination. 5 tiers × 3 overrides × 13 capabilities = 195 cases; condensed to ~30 representative table-driven assertions.
- `RevenueCatWebhookControllerTests` — HMAC validation (reject bad sig), idempotency on `event.id`, every event type → expected `users.tier` transition. Use canned RC payloads from RC's sandbox docs.

### Integration tests

- `M21_AddTierFieldsTests` — migration idempotent, doesn't break M17 rows (existing `'free'` → `'trial'`, `'pro'` preserved).
- `LapseArchiverTests` — fixture user trial expired → tier flips to lapsed on next cron; +90 d → archived + vault moved; +275 d → hard delete; happy path + error path.
- `EnforcementBypassTests` — `billing.enforcementEnabled=false` → middleware no-op even when tier=`lapsed`. Set to `true` → 402 as expected.

### iOS tests

- `BillingServiceTests` — mock RC SDK with sandbox-style entitlement responses, verify `Entitlement` enum updates.
- `EntitlementGateTests` — view modifier renders PaywallView on 402, transparent on 200.

### End-to-end

- Bruno suite `bruno/Billing/`:
  - `RevenueCat Webhook - Initial Purchase.bru` (signed fixture payload)
  - `RevenueCat Webhook - Renewal.bru`
  - `RevenueCat Webhook - Cancellation.bru`
  - `Me - Billing Status.bru`
  - `Admin - Set Tier Override.bru`
- Apple sandbox account: full purchase flow (sandbox → RC sandbox → server → tier flip).

## Open decisions / known unknowns

1. **Final pricing**: $14.99 / $29.99 are anchors. Product call before launch. RC supports tier price changes without code deploy.
2. **Annual plan**: skip v1. Apple recommends annual for retention but conversion data should drive timing. Add when MRR > $10 K and we see month-3 churn.
3. **Family Sharing**: out of scope v1. Apple supports it on subscriptions but multi-tenancy testing surface is non-trivial.
4. **Android / web**: RevenueCat supports both. Out of scope v1; spec is iOS-only. Webhook payload shape is identical across platforms.
5. **Founders / lifetime tier**: rejected during brainstorm. Re-evaluate post-launch when community sentiment is clearer.
6. **Free-tier migration**: M17 introduced `'free'` enum value but no production user ever landed there (M17 not yet deployed at time of this spec). M21 simply replaces M17's enum before any rows of value exist.
7. **What happens to running skills during lapse**: nightly cron skips users where `tier IN ('lapsed', 'archived')`. Mid-run skills (event-driven) complete the current iteration but don't enqueue follow-up work.
8. **Hermes gateway vs direct provider wrapping**: this spec assumes Hermes gateway architecture (current state). An alternative would be to skip the gateway entirely and have the server call Anthropic / OpenAI / Together directly via the routing layer (HER-161..166) — collapses two hops to one and removes the per-user `X-Hermes-Profile` provisioning step. **Decision: keep Hermes for now.** The gateway gives us a clean seam for future programmability (per-user prompt rewriting, per-profile policy enforcement, cheap multi-tenant routing, ability to swap inference vendors without touching application code). Cost: one extra service to operate, per-user profile lifecycle to manage. If the operational cost outweighs the programmability win at >1 K DAU, re-evaluate then. Capture this as a separate spec, not in this billing PR.

## Implementation phases

Single PR is too big. Three sub-PRs:

| Phase | Scope | Linear cluster |
|---|---|---|
| **B1 — Schema + checker** | M21 migration, `EntitlementChecker`, capability enum, unit tests. No middleware wired yet. | 1 ticket |
| **B2 — Webhook + iOS billing service** | RevenueCatWebhookController, RevenueCatClient, BillingService (iOS), entitlement summary endpoint. Webhook fully functional but enforcement flag stays off. | 2 tickets (server + iOS) |
| **B3 — Middleware + paywall UI + lapse cron** | EntitlementMiddleware, EntitlementGate (iOS), LapseArchiver skill, all Bruno coverage. Enforcement flag still defaults to off; flip is a runbook step on launch day. | 2 tickets (server + iOS) |

Five total tickets to file. All Backend MVP / iOS MVP projects.

## Critical files

### New (server)

- `Sources/App/Billing/RevenueCatWebhookController.swift`
- `Sources/App/Billing/EntitlementMiddleware.swift`
- `Sources/App/Billing/EntitlementChecker.swift`
- `Sources/App/Billing/RevenueCatClient.swift`
- `Sources/App/Migrations/M21_AddTierFields.swift`
- `Resources/Skills/lapse-archiver/SKILL.md` (or `Sources/App/Skills/LapseArchiverSkill.swift` if not modeled as a skill)
- `Tests/AppTests/Billing/EntitlementCheckerTests.swift`
- `Tests/AppTests/Billing/RevenueCatWebhookControllerTests.swift`
- `Tests/AppTests/Billing/LapseArchiverTests.swift`
- `bruno/Billing/` (5 .bru files)

### New (iOS)

- `LuminaVaultClient/.../Billing/BillingService.swift`
- `LuminaVaultClient/.../Billing/EntitlementGate.swift`
- `LuminaVaultClient/.../Billing/PaywallView.swift` (thin wrapper over RC SDK component)
- `LuminaVaultClient/.../Billing/BillingClient.swift`

### Modify

- `Sources/App/Models/User.swift` — `tier` becomes new enum, add `tier_expires_at`, `tier_override`, `revenuecat_user_id` fields
- `Sources/App/Services/AuthService.swift` — on register, set `tier='trial'`, `tier_expires_at=NOW()+14d`
- `Sources/App/App+build.swift` — register `EntitlementMiddleware` on protected route groups; wire RevenueCat webhook controller
- `docs/llm-models.md` — replace §1 (tiered hosting) with new Trial / Pro / Ultimate table; update §7 (cost guardrails) — Pro Mtok cap is 10 M, Ultimate uncapped, no Free tier
- `docs/jobs.md` — append `lapse-archiver` to job catalog
- `Package.swift` — no new server deps (RevenueCat is iOS-only; server uses webhooks + REST)
- iOS Package.swift — add `RevenueCat` SDK

### Superseded

- HER-174 (Stripe-based tier) — close with link to new tickets filed from this spec
- M17 migration enum (`'free','pro'`) — replaced by M21
