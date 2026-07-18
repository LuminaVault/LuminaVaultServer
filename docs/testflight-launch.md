# TestFlight Launch — Provisioning & Cutover Checklist

This is the operator checklist for taking LuminaVault to **TestFlight** and
later the **App Store**. Shipping is **dual-track**:

| Track | Bundle ID | ASC app | Fastlane |
| --- | --- | --- | --- |
| TestFlight | `com.lumina.fernando.beta` | Exists today | `fastlane beta` |
| App Store | `com.lumina.fernando` | Create later | `fastlane release` |

Both tracks hit the **same API** (`https://api.luminavault.fyi` / production host)
and the **same Postgres**. Auth audiences / APNS topics differ per bundle ID —
configure the server for the track you are testing (or accept both if you run
dual OAuth/APNS setup).

Client Fastlane + match details: `LuminaVaultClient/docs/TESTFLIGHT.md`.
**This doc is the human-provisioned half**: external accounts, keys, DNS, and
the host `.env.production`. Code can't create these accounts for you.

Legend: ☐ = you do it. Each item ends with **→ where the value goes**.

---

## 1. Apple Developer (developer.apple.com)

- ☐ **App IDs** (explicit) with capabilities enabled on each:
  Sign in with Apple, Push Notifications, Associated Domains, HealthKit,
  App Groups (`group.com.lumina.fernando`), Keychain Sharing.
  - TestFlight host: `com.lumina.fernando.beta`
  - TestFlight share extension: `com.lumina.fernando.beta.LuminaVaultShareExtension`
  - Production host (later): `com.lumina.fernando`
  - Production share extension (later): `com.lumina.fernando.LuminaVaultShareExtension`
- ☐ **APNs Auth Key** (Keys → +, APNs). Download the `.p8` **once**.
  → `.p8` to host `./secrets/apns-key.p8`; note **Key ID** → `APNS_KEYID`;
  Team ID is `84X9WYBF36` → `APNS_TEAMID`. Set `APNS_BUNDLE_ID` to the
  shipping track you are testing (`…beta` for TestFlight).
- ☐ **Associated Domain** is served by the API already
  (`https://api.luminavault.fyi/.well-known/apple-app-site-association`).
  Include **both** team-prefixed app IDs in `webcredentials.apps` when
  production ships: `84X9WYBF36.com.lumina.fernando.beta` and
  `84X9WYBF36.com.lumina.fernando`.
- ☐ **App Store Connect**:
  - TestFlight app for `com.lumina.fernando.beta` (exists) — internal testers.
  - Production app for `com.lumina.fernando` — create when ready for App Store.
- ☐ **fastlane signing**: private **match** certs repo + **App Store
  Connect API key** (.p8 + Key ID + Issuer ID).
  → GitHub secrets: `MATCH_GIT_URL`, `MATCH_PASSWORD`,
  `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_KEY_ISSUER_ID`,
  `APP_STORE_CONNECT_API_KEY_KEY` (base64), `FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD`.
  Seed beta: `bundle exec fastlane sync_signing` in the client repo.
  Seed production later: `SEED_PRODUCTION=1 bundle exec fastlane sync_signing`.

> Sign in with Apple native flow: the identity-token `aud` is the **shipping
> bundle ID** (beta or production). Server `OAUTH_APPLE_CLIENTID` must accept
> the audience for the track under test (see §6).

## 2. Google Cloud (console.cloud.google.com)

- ☐ OAuth consent screen configured.
- ☐ **iOS OAuth client** for bundle `com.lumina.fernando`.
  → client id `…apps.googleusercontent.com` → client `GID_CLIENT_ID` **and**
  server `OAUTH_GOOGLE_CLIENTID` (must be identical — server checks `aud`);
  reversed form → client `REVERSED_CLIENT_ID`.

## 3. X / Twitter (developer.twitter.com)

- ☐ OAuth 2.0 app (Native), API v2 access (for `/2/users/me`).
- ☐ Callback URL `luminavault://oauth/x/callback`.
  → client `X_CLIENT_ID`; server `OAUTH_X_CLIENTID`.

## 4. Twilio (phone OTP)

- ☐ Account + an SMS-capable number (E.164, e.g. `+1555…`).
  → host env: `SMS_KIND=twilio`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`,
  `TWILIO_FROM_NUMBER`.

## 5. Resend (email magic-link / password reset / MFA / verification)

- ☐ Verify the sender **domain** (SPF + DKIM); create an API key.
  → host env: `EMAIL_KIND=resend`, `EMAIL_RESEND_APIKEY`,
  `EMAIL_FROM_ADDRESS=noreply@<verified-domain>`, `EMAIL_REPLY_TO` (optional).

## 6. Host `.env.production` (`/opt/obsidian-claudebrain/.env.production`)

Hand-managed on the VPS — **not** committed and **not** pushed by the deploy
workflow (which only injects `APP_IMAGE`/`POSTHOG`/`SENTRY`/`BACKUP`). Set:

```dotenv
# --- core / secrets ---
POSTGRES_PASSWORD=<strong>
JWT_HMAC_SECRET=<openssl rand -base64 32>      # or JWT_HMAC_SECRETS=kid:secret,... for rotation
HERMES_API_KEY=<32-byte hex>                    # `make hermes-bootstrap`
LV_SECRET_MASTER_KEY=<openssl rand -base64 32>  # 32 bytes b64 — enables SecretBox / per-user creds
CORS_ALLOWEDORIGINS=https://app.luminavault.fyi # compose marks this REQUIRED; set web origin(s)

# --- OAuth (empty = provider disabled) ---
OAUTH_APPLE_CLIENTID=com.lumina.fernando
OAUTH_GOOGLE_CLIENTID=<google ios client id>
OAUTH_X_CLIENTID=<x client id>

# --- email ---
EMAIL_KIND=resend
EMAIL_RESEND_APIKEY=<resend key>
EMAIL_FROM_ADDRESS=noreply@<verified-domain>
EMAIL_REPLY_TO=

# --- phone OTP ---
SMS_KIND=twilio
TWILIO_ACCOUNT_SID=<sid>
TWILIO_AUTH_TOKEN=<token>
TWILIO_FROM_NUMBER=+1555XXXXXXX

# --- WebAuthn / passkeys ---
WEBAUTHN_ENABLED=true
WEBAUTHN_RELYINGPARTYID=api.luminavault.fyi
WEBAUTHN_RELYINGPARTYNAME=LuminaVault
WEBAUTHN_RELYINGPARTYORIGIN=https://api.luminavault.fyi

# --- APNS (production) ---
APNS_ENABLED=true
APNS_BUNDLEID=com.lumina.fernando
APNS_TEAMID=84X9WYBF36
APNS_KEYID=<apns key id>
APNS_PRIVATEKEYPATH=/app/secrets/apns-key.p8
APNS_ENVIRONMENT=production
```

> **Never** set `PHONE_FIXED_OTP` / `MAGIC_FIXED_OTP` in production — they are
> auth backdoors (anyone with the value signs in as anyone).

Also place `./secrets/apns-key.p8` on the host (mounted read-only into the app
at `/app/secrets`).

## 7. DNS + TLS cutover

- ☐ Set the ACME contact in the root `Caddyfile` (`email REPLACE_WITH_OPS_EMAIL`).
- ☐ DNS records → the VPS public IP:
  ```text
  A     api.luminavault.fyi.  <VPS-IPv4>  300
  AAAA  api.luminavault.fyi.  <VPS-IPv6>  300
  CAA   api.luminavault.fyi.  0 issue "letsencrypt.org"  3600
  ```
- ☐ Firewall: 80 + 443 (tcp **and** udp/443 for HTTP/3) open. Caddy mints the
  cert on first request once DNS resolves.

## 8. iOS shipping configs (client repo)

- **TestFlight now**: fill `LuminaVaultClient/Config/Config.Beta.xcconfig`
  (`GID_CLIENT_ID`, OAuth, RevenueCat public key, etc.). Ship with
  `bundle exec fastlane beta`.
- **App Store later**: fill `Config.Release.xcconfig`, create the ASC app,
  seed production match profiles, then `bundle exec fastlane release`.

Entitlements (`aps-environment=production` for Beta/Release archives,
`webcredentials:…`) and dual Fastlane lanes live in the client repo.

---

## 9. Cutover order

1. Provision §1–§5; fill §8 xcconfig; put secrets in §6 + the `.p8` on host.
2. Deploy server (push to `main` → CI → deploy). First deploy: bring up the full
   stack once so `postgres`/`hermes`/`caddy` exist:
   `docker compose -p prod -f docker-compose.production.yml --env-file .env.production up -d`.
3. Confirm the Deploy workflow's `app migrate` step succeeded. It runs after
   PostgreSQL is healthy and before the API container is replaced. For an
   initial manual bootstrap only, run:
   `docker compose -p prod -f docker-compose.production.yml --env-file .env.production run --rm --no-deps app migrate`.
4. Point DNS (§7); wait for Caddy `certificate obtained successfully`.
5. In the client repo: `bundle exec fastlane sync_signing` then
   `bundle exec fastlane beta` (builds **Beta** / `com.lumina.fernando.beta`,
   uploads to TestFlight).
6. Install via TestFlight; smoke every auth (§10).
7. When the production ASC app exists: `SEED_PRODUCTION=1 bundle exec fastlane sync_signing`
   then `bundle exec fastlane release` for an App Store draft.

## 10. Auth smoke matrix (TestFlight build, live API)

| Method            | Needs (§) | Pass = |
|-------------------|-----------|--------|
| Email + password (+reset, +MFA) | 5 | register/login OK; reset + MFA email arrives |
| Email magic-link  | 5 | OTP email arrives, verify issues session |
| Phone OTP         | 4 | SMS arrives, verify issues session |
| Sign in with Apple| 1 | exchange returns session |
| Google            | 2 | exchange returns session |
| X                 | 3 | exchange returns session |
| Passkey reg + auth| 1, 6, 7 | system passkey sheet; register + authenticate OK |
| Push notification | 1, 6 | a notification arrives (production APNS) |
| HTTP/2            | 7 | `curl -I --http2 https://api.luminavault.fyi/health` → `HTTP/2 200` |

See [`hetzner-deployment.md`](./hetzner-deployment.md) for host/proxy detail and
[`deploy.md`](./deploy.md) for the CI/CD pipeline + rollback.
