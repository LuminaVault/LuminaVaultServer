# Auth — remaining setup (TODO)

Audit 2026-06-02. The dev wiring gaps are fixed (`docker-compose.yml` now passes
the auth env through from `.env`; a dev `LV_SECRET_MASTER_KEY` is set). The items
below still need external credentials or a deliberate flip before each auth method
is fully functional.

## Config key-name rules (read first)

The server config layer (`ConfigReader`) maps a dotted key to an env var by
uppercasing, replacing `.` with `_`, and **preserving camelCase with no extra
underscore**:

| Config key | Env var |
|---|---|
| `oauth.apple.clientId` | `OAUTH_APPLE_CLIENTID` |
| `oauth.x.clientId` | `OAUTH_X_CLIENTID` |
| `webauthn.relyingPartyId` | `WEBAUTHN_RELYINGPARTYID` |
| `sms.kind` / `email.kind` | `SMS_KIND` / `EMAIL_KIND` |

Wrong names (`WEBAUTHN_RELYING_PARTY_ID`, `OPEN_ROUTER_API_KEY`) silently fall
through to defaults — that was the original bug.

Where to set values:
- **Dev/local:** `LuminaVaultServer/.env` (gitignored). Apply with
  `make dev-down && make dev-up`.
- **VPS/prod:** `.env.production` on the host. `docker-compose.production.yml`
  already passes every var; just populate + redeploy.

---

## 1. Apple Sign-In

**State:** client always shows the "Sign in with Apple" button, but the server
has no `OAUTH_APPLE_CLIENTID`, so the token exchange fails on tap.

**Server config**
- `OAUTH_APPLE_CLIENTID` = the Apple **Services ID** (e.g. `com.luminavault.signin`).
  `AppleOAuthProvider` verifies the identity-token `aud` against it.

**Apple Developer portal**
1. Identifiers → register an **App ID** with "Sign In with Apple" capability.
2. Identifiers → register a **Services ID**; enable Sign In with Apple; set the
   return URL / associated domain.
3. (For the JWT client-secret flow, if used) create a Sign In with Apple **Key**
   (.p8) + note Key ID + Team ID. Confirm whether `AppleOAuthProvider` needs a
   client secret or only audience verification before wiring a key.

**Client (LuminaVaultClient)**
- Add the **Sign in with Apple** capability/entitlement to the app target.
- Gate the Apple button on a configured flag (or hide it) so it does not appear
  while the server has no client ID — today it is shown unconditionally
  (`AuthLandingView` adds `.apple` to `providers` with no guard). Code TODO.

**Verify:** tap Apple → completes ASAuthorization → server `/oauth/...` exchange
returns a session JWT.

---

## 2. X (Twitter) OAuth

**State:** `OAUTH_X_CLIENTID` absent → client hides the X button
(`Config.xClientID == nil`). It is OAuth2 + PKCE (public client, **no secret**).

**Server config**
- `OAUTH_X_CLIENTID` = the X app's OAuth2 Client ID. Endpoint:
  `POST /v1/auth/oauth/x/exchange` (PKCE code exchange via `XOAuthController`).

**X Developer portal**
1. Create a project + app; enable **OAuth 2.0**, type **Native/Public client**
   (PKCE, no client secret).
2. Set the redirect/callback the client uses; scopes `users.read tweet.read`.
3. Copy the **Client ID**.

**Client**
- Set the X client ID in client `Config` so `Config.xClientID` is non-nil and the
  button appears.

**Verify:** X button visible → auth → `/oauth/x/exchange` → session.

---

## 3. Real SMS + email (currently logging-mode)

**State:** `SMS_KIND` and `EMAIL_KIND` default to `logging` — phone OTP and
email magic-link / MFA codes are written to server **stderr**, not delivered.
Fine for dev; not for prod.

**SMS (Twilio)**
- `SMS_KIND=twilio`
- `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER`
- Twilio console: buy a sending number, copy Account SID + Auth Token.

**Email (Resend)**
- `EMAIL_KIND=resend`
- `EMAIL_RESEND_APIKEY`, `EMAIL_FROM_ADDRESS` (on a **verified** domain),
  optional `EMAIL_REPLYTO`.
- Resend: add + verify the sending domain (DNS), create an API key.

**Verify:** request a phone OTP / magic link → real SMS / email arrives.
Do **not** rely on `PHONE_FIXED_OTP` / `MAGIC_FIXED_OTP` in prod — dev/CI backdoors.

---

## 4. Passkeys / WebAuthn

**State:** key names fixed; `WEBAUTHN_ENABLED=false`, so the server WebAuthn
service is off.

**Dev (web origin / simulator)**
- Flip `WEBAUTHN_ENABLED=true`. Keep `WEBAUTHN_RELYINGPARTYID=localhost`,
  `WEBAUTHN_RELYINGPARTYORIGIN=http://localhost:8080`.

**Prod / real iOS passkeys**
- `WEBAUTHN_RELYINGPARTYID` = the apex domain (e.g. `luminavault.app`).
- `WEBAUTHN_RELYINGPARTYORIGIN` = `https://<that domain>`.
- iOS requires an **Associated Domains** entitlement (`webcredentials:<domain>`)
  and an `apple-app-site-association` file served at the domain. The RP ID must
  match the associated domain — `localhost` will not work from a device.

**Verify:** register a passkey from the client → server stores the credential →
subsequent passkey sign-in succeeds.

---

## 5. VPS / production (78.46.192.73)

`docker-compose.production.yml` is already wired to pass every auth var; the host
`.env.production` must populate them, then redeploy.

Required on the VPS (at minimum):
- `JWT_HMAC_SECRET` (or `JWT_HMAC_SECRETS` for rotation) — a strong unique value.
- `LV_SECRET_MASTER_KEY` — **generate once on the VPS** (`openssl rand -base64 32`),
  store securely, **never lose or rotate carelessly**: it encrypts all BYOK keys +
  BYO Hermes tokens + connector secrets at rest. Losing it = those rows become
  undecryptable. Must be **distinct** from the dev key.
- `OAUTH_GOOGLE_CLIENTID` (matches the iOS client), `OAUTH_APPLE_CLIENTID`,
  `OAUTH_X_CLIENTID` as each provider is enabled.
- `WEBAUTHN_ENABLED=true` + real `WEBAUTHN_RELYINGPARTYID/ORIGIN`.
- `SMS_KIND=twilio` + Twilio creds; `EMAIL_KIND=resend` + Resend creds.
- `ADMIN_TOKEN` — non-empty to unlock admin endpoints (HER-330 Hermes self-update).
- `OPENROUTER_API_KEY` — managed-brain default model key (HER-300).

**Steps:** edit `.env.production` on the host → `docker compose -f
docker-compose.production.yml up -d` (or the deploy pipeline) → check
`/health` + try each enabled auth method.

---

## Quick status table

| Method | Dev | Prod | Blocker |
|---|---|---|---|
| Username/password | ✅ | ✅ | — |
| Phone OTP | logging | logging | Twilio creds |
| Email magic link / MFA | logging | logging | Resend creds |
| Google | ✅ (wired) | ✅ if env set | — |
| Apple | ❌ | ❌ | `OAUTH_APPLE_CLIENTID` + client entitlement + button gating |
| X | ❌ (hidden) | ❌ | `OAUTH_X_CLIENTID` |
| Passkey / WebAuthn | off (flip flag) | off | enable + real RP domain (assoc. domains) |
| BYOK provider keys | ✅ (master key set) | needs VPS master key | — |
| BYO Hermes | ✅ (master key set) | needs VPS master key | — |
