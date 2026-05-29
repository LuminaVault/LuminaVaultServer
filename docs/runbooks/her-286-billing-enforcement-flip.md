# Runbook — HER-286: Launch-day billing enforcement flip

**Status:** Documented, **not yet executed**. Blocked on production VPS provisioning (no prod host exists at time of writing). Execute when the VPS is live.

## What this is

Server-side billing enforcement ships behind a kill-switch. While off, `EntitlementMiddleware` authorizes every request and no `402` paywall ever fires — so the iOS paywall sheet (HER-211) is inert in production. This runbook flips the switch on so trial-expired / `lapsed` / `archived` users start receiving `402` on the protected routes.

**No code change.** Single `.env` edit + app container restart. Recovery is instant and stateless.

## Config facts (verified against source)

- Config key: `billing.enforcementEnabled`, read in `Sources/App/App+build.swift`:
  ```swift
  billingEnforcementEnabled: reader.string(forKey: "billing.enforcementEnabled", default: "false").lowercased() == "true"
  ```
- Env var: `BILLING_ENFORCEMENT_ENABLED` (`.env.example:147`, default `false`).
- `docker-compose.production.yml` declares `${BILLING_ENFORCEMENT_ENABLED:-true}` — an *unset* var defaults to `true`; the explicit `false` in `.env` is what currently holds enforcement off. Keep the flip explicit (`=true`) for legibility.

## Routes that begin enforcing on flip

Middleware-protected mount sites that return `402 { paywall_id, required_tier }` for non-entitled tiers:

- `POST /v1/grok/chat` (chat — 2 mount points)
- `POST /v1/memory/query` (memoryQuery — 3 mount points)
- `POST /v1/capture/safari` (capture — 2 mount points)
- `POST /v1/memos` (memoGenerator)
- `POST /v1/kb/compile` (kbCompile)
- `POST /v1/health/ingest` (healthIngest)
- Skills runs (`SkillsController.swift`)

iOS surface that converges on those 402s: universal `BaseHTTPClient.onPaymentRequired` → `AppState.pendingPaywallID` → root `.sheet(item:)` in `LuminaVaultClientApp`; plus HER-188 `EntitlementGate` handlers where wired.

## Prerequisites

**Infra (current blocker):**

- [ ] Production VPS provisioned, Docker + compose installed, LuminaVaultServer working dir deployed, `/v1/health` returning 200.

**Product / billing (re-confirm before flip):**

- [ ] HER-271 — ASC product config live (4 SKUs, RC `default` offering wired, sandbox purchase elevates `BillingService.currentTier`).
- [ ] HER-272 — CI/CD VPS deploy path + rollback runbook.
- [ ] HER-211 — iOS paywall on a TestFlight build; subscribe / restore / manage green on ≥1 device.

**Operational guards:**

- [ ] RevenueCat webhook `POST /v1/billing/revenuecat` reachable from RC egress IPs — test via RC dashboard "Send test event".
- [ ] Sentry alert for a spike in `APIError.paymentRequired` from the iOS client.
- [ ] Grafana / VPS dashboard for `/v1/auth/me/billing` p95 latency (expect uptick post-flip).
- [ ] Rollback rehearsed on staging: `=false` + restart returns to allow-all in <30 s.
- [ ] A known `.lapsed` test account on hand to provoke a `402`.

> **Sequencing note:** HER-296 (real testimonials for the App Review screenshot) is **not** a blocker for this server flip. It gates *public App Store submission*. Flipping in a TestFlight-only context is safe — no public App Store users exist yet to be gated, and TestFlight testers have a working purchase path via HER-271.

## Execution (on VPS, low-traffic window ~03:00 UTC)

1. SSH to the VPS, `cd` to the LuminaVaultServer working dir.
2. Flip the env var:
   ```bash
   sed -i 's/BILLING_ENFORCEMENT_ENABLED=false/BILLING_ENFORCEMENT_ENABLED=true/' .env
   grep BILLING_ENFORCEMENT_ENABLED .env   # confirm =true
   ```
3. Restart only the app container:
   ```bash
   docker compose -f docker-compose.production.yml up -d --no-deps app
   ```
4. Smoke `/v1/health` until 200.
5. From a known `.lapsed` test account, hit a protected route (e.g. `POST /v1/memory/query`); confirm `402 { paywall_id, required_tier }` and that the paywall sheet surfaces in the iOS app. Confirm an entitled account still gets `200`.
6. Watch Sentry + Grafana ~30 min for `paymentRequired` spikes and `/v1/auth/me/billing` latency.

## Rollback (instant, stateless)

```bash
sed -i 's/BILLING_ENFORCEMENT_ENABLED=true/BILLING_ENFORCEMENT_ENABLED=false/' .env
docker compose -f docker-compose.production.yml up -d --no-deps app
```

Server returns to allow-all in <30 s.

## Out of scope

- Tier downgrade grace-period semantics (owned by EntitlementMiddleware / billing-state machine).
- Customer comms before the flip.
- HER-296 testimonials / App Review screenshot (separate launch blocker for public release).
