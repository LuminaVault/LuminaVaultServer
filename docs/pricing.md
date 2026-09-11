# Pricing, tiers and RevenueCat

The single record of what we sell and what must be configured for it to work.
Five artifacts used to carry four different price lists; if any of them
disagrees with this file, this file is right and the other is a bug.

Last reconciled 2026-09-11 (free tier, `M124_AddFreeTier`).

---

## What we sell

| Tier | Monthly | Yearly |
|---|---|---|
| **Pro** | `pro_monthly_14_99` — $14.99 | `pro_yearly_149_99` — $149.99 |
| **Ultimate** | `ultimate_monthly_29_99` — $29.99 | `ultimate_yearly_299_99` — $299.99 |

Defined once in code: `Sources/App/Billing/SubscriptionCatalog.swift`, mirrored
on the client in `Services/Billing/RCProduct.swift` and pinned by
`TrialCountdownBannerVisibilityTests.testProductIDsMatchSpec`.

**Matching is exact.** The webhook used to decide with
`pid.contains("ultimate")` then `pid.contains("pro")`, which sold Pro for any
id containing `promo`, `professional` or `product`, and silently granted
nothing for an id matching neither. A product id RevenueCat reports that is
not in the table above now **throws**, which skips the user save *and* the
`billing_event_logs` row, so RevenueCat retries instead of seeing success.

Adding a SKU means adding it here **and** in App Store Connect **and** in
RevenueCat. Adding it in ASC alone produces a webhook that retries forever.

---

## Tiers

`users.tier`, CHECK-constrained by `M15_AddTierFields` and widened by
`M124_AddFreeTier` to exactly: `free`, `trial`, `pro`, `ultimate`, `lapsed`,
`archived`.

There is still **no `byok` tier**, however marketing describes it. The BYO
exemption (`BYOEntitlementPolicy`) is an orthogonal mechanism, not a row in
this column. The free *lane* (`FreeLanePolicy`) is likewise not the same thing
as the free *tier*: the tier says what you may call, the lane says who pays
for it.

| Tier | How you get here | What it grants |
|---|---|---|
| `free` | your 14-day trial ended | chat, memory and capture on the free lane, 20 messages/day; read and export your vault. No workflows, no skills, no platform-funded routes |
| `trial` | signup, 14 days | everything except the four ultimate-only capabilities |
| `pro` | a Pro SKU | the same, and keeps it |
| `ultimate` | an Ultimate SKU | everything |
| `lapsed` | a **paid** subscription expired | the same as `free`, plus a 90-day archive clock |
| `archived` | 90 days lapsed | nothing; vault moved to cold storage |

Hard delete at 365 days archived (`LapseArchiverJob`). `tier_override`
(`none|pro|ultimate`, admin-only) raises the floor and **exempts a user from
lapsing entirely** — the mechanism to use for testers.

Note `lapsed` is no longer where an expired trial lands: `LapseArchiverJob`
sends a trial to `free` and only a lapsed *subscription* to `lapsed`. Before
the split, "your subscription expired" was the copy shown to someone who had
never subscribed, and it started a cold-storage clock on them.

### Capability matrix

`Sources/App/Billing/EntitlementChecker.swift` is authoritative. Summary:

- **Always, except archived:** `vaultRead`, `vaultExport`, `chat`,
  `memoryQuery`, `capture`
- **trial / pro / ultimate:** `healthIngest`, `memoGenerator`,
  `skillBuiltinRun`, `kbCompile`, `memoryCompile`, `workflowAutomation`
- **ultimate only:** `skillVaultRun`, `privacyBYOKey`, `privacyContextRouter`,
  `mlxOnDevice`

`free` and `lapsed` share a row deliberately. An ex-subscriber getting
strictly less than someone who never paid is indefensible; the two differ only
in the archive clock and the storage ceiling (`free` 1 GiB, `lapsed` no
growth).

Chat being free costs nothing by construction: a non-paying tier reaches an
LLM only through `FreeLanePolicy`'s zero-cost lane, capped daily by
`FreeLaneGate`. What that argument does **not** cover is the three routes that
spend a platform key with no bring-your-own path — `/v1/transcribe` (Groq),
`/v1/tts` (OpenAI), `/v1/vision` (Cohere). They are marked `platformFunded` at
the mount, and that flag now carries a **tier floor of `trial`** as well as
suppressing the BYO exemption. Without the floor, entitlement alone would hand
every free account 200 transcriptions, 1000 TTS calls and 200 vision embeds a
day on our account.

### BYO exemption

A tenant on their own Hermes or their own provider key is exempt from the
paywall for the capabilities **they** pay to run — see
`Sources/App/Billing/BYOEntitlementPolicy.swift`. The four ultimate-only
capabilities are never exempted: they are the product's paid surface, not a
question of who pays for tokens. `archived` is never exempted.

Capabilities we buy from a third party on the user's behalf — transcription
(Groq), TTS (OpenAI), vision embeddings (Cohere) — stay gated regardless of
BYO, because none of those three adapters takes a `UserCredentialStore` and
none has a bring-your-own path. They are marked `platformFunded: true` at the
mount in `App+build.swift`, **not** by capability: `/v1/transcribe` and
`/v1/tts` both require `.chat`, the same capability as `/v1/llm`, which does
run on the user's key. Exempting them was worth 200 transcriptions, 1000 TTS
calls and 200 vision embeds a day per lapsed BYO user, on our account.

**What counts as "their own key"** — `ProviderKind.isSpendable`. A row is proof
of BYO only if it carries a non-empty API key, or (for `.ollama` and `.custom`
alone, which address a server the user runs and commonly has no auth) a base
URL with a scheme and a host. The old test accepted any non-nil `baseURL`, so
saving a bare URL against *any* provider unlocked the paid surface — with a row
that, for every provider that authenticates, cannot buy a single token.

---

## RevenueCat — required configuration

Nothing below is optional for selling. None of it is needed to *test on
TestFlight* (see the next section).

1. **Products** — the four SKUs above, in App Store Connect. Bundle
   `com.lumina.fernando`, subscription group `LV Subscriptions`.
2. **Entitlements** — exactly two, lowercase **`pro`** and **`ultimate`**,
   each attached to its two products. `BillingService.swift:23-26` compares
   these strings literally.
3. **A current offering with at least one package**, id `default`.
   `RevenueCatUI.PaywallView()` renders the *current* offering and nothing
   else. A configured SDK with an empty offering draws a blank sheet — and RC
   builds its error view with `releaseBehavior: .fatalError`, so a failed
   offering fetch is a hard crash in a release build. `PaywallView` guards
   this by checking `availablePackages.isEmpty` and degrading to
   "Subscriptions unavailable", but the guard is a seatbelt, not a fix.
4. **Webhook** → `POST https://api.luminavault.fyi/v1/billing/revenuecat-webhook`
   with header `Authorization: Bearer <REVENUECAT_WEBHOOK_SECRET>`, matching
   the deployed secret.
   **Do not trust older docs for this path.** Three of them carried
   `/v1/billing/webhooks/revenuecat` or `/v1/billing/revenuecat`, and the host
   as `.com`. Any of those 404s every event, and no tier ever updates.
5. **App user id must be the server user UUID** — handled automatically by
   `BillingService.bootstrap` → `purchases.logIn(userID.uuidString)`.
6. **SDK key.** `Config.Release.xcconfig` has a real `appl_` public key.
   `Config.Beta.xcconfig` declares the key **empty**, so TestFlight builds
   boot with billing inert. Populate it only when you want purchases testable
   on TestFlight. Never the secret key.

### Events we act on

| Event | Effect |
|---|---|
| `INITIAL_PURCHASE`, `PRODUCT_CHANGE`, `RENEWAL`, `UNCANCELLATION` | grant the SKU's tier + set expiry |
| `CANCELLATION` | lapse **only** on refund or an already-past expiry — cancelling turns off auto-renew, it does not revoke what was paid for |
| `EXPIRATION` | lapse |
| `BILLING_ISSUE` | hold the tier and push the expiry past the retry window (16 days) |
| anything else | logged, ignored |

`RENEWAL` used to write only the expiry. A subscriber already flipped to
`lapsed` by an earlier *missed* renewal therefore renewed successfully, got a
future expiry, and stayed locked out permanently — there is no reconciliation
loop, and their vault would be cold-archived at 90 days. Granting on every
paid event fixes that.

---

## Testing on TestFlight

**You do not need any RevenueCat configuration to test on TestFlight.**

TestFlight builds the **Beta** configuration, whose `LV_RC_API_KEY` is empty.
`Config.swift` rejects an empty key, `Purchases.configure` is skipped, and
`Purchases.isConfigured` is false — no SDK, no offerings fetch, no crash. A
tester who reaches the paywall sees "Subscriptions unavailable", which is
accurate for a build that cannot sell.

The empty Beta `LV_RC_API_KEY` is **correct and needs no RevenueCat dashboard
change.** A tester who reaches the paywall should see "Purchases aren't
available in this build", with a working Close — if they instead see a bare
mascot and nothing else, that is a client bug in `PaywallView`, not a
misconfiguration.

**What used to bite testers is enforcement, not RevenueCat.**
`BILLING_ENFORCEMENT_ENABLED` defaults to **true** in
`docker-compose.production.yml` when the variable is unset — the opposite of
the code default — and `LapseArchiverJob` moves every account off `trial` 14
days after signup. That tester now lands on `free`, which keeps chat, memory
and capture, so the cliff is much smaller than it was: what they lose is
workflows, skills, the compilers, and transcription/TTS/vision.

Two ways to grant a tester the full product — they are idempotent with each
other, and either one also exempts the account from `LapseArchiverJob`:

- `BILLING_TIER_OVERRIDE_EMAILS` — a comma list of `email=tier` (a bare email
  grants `ultimate`). Stamped onto `users.tier_override` by
  `DefaultAuthService.issueTokens`, so it applies on the account's **next
  sign-in or token refresh**, never mid-session. It must be present in
  `.env.production` on the host, not merely passed through
  `docker-compose.production.yml`, or it resolves to empty.
- The admin call below, for an immediate grant.

Give each tester an override instead of disabling enforcement globally — a
user with an override is skipped by the lapse job entirely:

```sh
curl -X PUT https://api.luminavault.fyi/v1/admin/users/<user-id>/tier-override \
  -H "X-Admin-Token: $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"tierOverride":"ultimate"}'
```

Worth pointing the webhook at the correct URL now even so: it costs a minute,
and leaving it wrong means debugging "tiers never update" later with no signal.

---

## Open decision: two trial clocks

The server grants **14 days** (`AuthService.applyTrialDefaults`, written at
registration and idempotent). The Apple introductory offer documented for the
monthly SKUs is **7 days**. Neither clock knows about the other, so a user can
be inside one and outside the other.

Not resolved. Pick one and make the other follow:

- **14 days everywhere** — change the ASC intro offer to 14 days. More trial,
  more time to reach the moat (importing a Hermes takes real setup).
- **7 days everywhere** — change `trialDays` to 7. Matches the store, shorter
  runway to a decision.

Until then, treat any statement about "the trial" as ambiguous.

---

## Known gaps

Recorded so they are not rediscovered:

- **The per-tenant Cerberus USD budget defaults to unlimited** — both limits
  are `nil`, so `RouterTelemetryService.reserve` always allows.
- **Storage quota covers ingestion only.** `StorageQuotaService` sums
  `vault_files.size_bytes` and gates `POST /v1/ingestions` — the only path
  that can write gigabytes. The other `VaultFile` writers (capture, memo
  generator, skill runner) persist text and are unmetered. Defaults: trial
  5 GiB, Pro 100 GiB, Ultimate 1 TiB, lapsed no growth.
- **No per-tenant USD cap.** `cost_ledger` now records managed spend, but
  `billing.managedDailyCapUsdMicros` defaults to 0 (disabled) — it ships as a
  meter, and setting a cap needs real numbers from it first.
- **No dormancy reaper for `free`.** `LapseArchiverJob` only ever archives
  `lapsed` rows, so a `free` account is never cold-stored and never hard
  deleted, however long it sits idle. Per account this is bounded by the 1 GiB
  `free` storage ceiling; across accounts it is not bounded at all. The fix is
  a dormancy rule keyed on last login — which needs a `last_seen_at` column
  that does not exist, because `tier_expires_at` on a `free` row is a stale
  trial timestamp and using it would delete live users' vaults.
- **The free lane's OpenRouter leg holds 45 requests/day platform-wide**
  against a per-user grace of 20, so roughly three active free users exhaust
  it. This is not the outage it looks like: legs cascade, and the next one
  (`nvidiaDirect`, 900/day) takes over — but it is a different model, so free
  users see a quality change rather than an error. 45 tracks OpenRouter's own
  free-tier ceiling of 50/day before $10 of credit is purchased, so raising it
  requires buying credit, not editing config. `FreeLaneGate` failing open on a
  SQL error is deliberate and documented: the lane it grants costs $0 by
  construction, so the blast radius is provider rate limits rather than money.
