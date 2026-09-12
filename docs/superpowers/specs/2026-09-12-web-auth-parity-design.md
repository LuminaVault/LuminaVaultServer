# Web auth parity — Google, Apple, Passkeys

**Date:** 2026-09-12
**Status:** Approved design, not implemented
**Repos:** LuminaVaultServer, LuminaVaultWebApp, LuminaVaultInfra

## Problem

The web app authenticates against the LuminaVault API with bearer tokens — the
same server as iOS, no parallel auth system. (A `better-auth` + drizzle scaffold
existed and was removed in audit W5; the stale add-on line in the web
`CLAUDE.md` is the only trace.)

What is missing is sign-in methods. Measured against iOS:

| Method | iOS | Web |
|---|---|---|
| Email + password | yes | yes |
| Device pairing | — | yes |
| MFA verify | yes | yes |
| Magic link (`email/start`) | yes | **no** |
| Phone OTP | yes | **no** |
| Passkeys / WebAuthn | yes | **no** |
| Apple / Google / X | yes | **no** |

The OAuth and WebAuthn endpoints appear in `src/lib/types/generated/api.d.ts`
because it is generated from `openapi.yaml` — no web application code calls
them. The web login page offers email, password and pair.

This is a demand blocker: a stranger cannot sign up on web the way they can on
iOS. Passkeys being absent on web while present on iOS is backwards — WebAuthn
is a browser standard.

**Scope of this design:** Google, Apple, Passkeys. Magic link and phone OTP are
out of scope (see [Out of scope](#out-of-scope)).

## Constraints discovered

### The relying-party ID blocks web passkeys outright

Production runs `WEBAUTHN_RELYING_PARTY_ID = api.luminavault.fyi`. The web app
serves from `app.luminavault.fyi`.

WebAuthn requires the RP ID to equal the caller's origin domain or be a
registrable suffix of it. A browser on `app.luminavault.fyi` may use
`app.luminavault.fyi` or `luminavault.fyi` — never the sibling
`api.luminavault.fyi`. The browser rejects the ceremony before the request
reaches the server.

**Decision: RP ID becomes `luminavault.fyi`.**

Credentials are bound to the RP ID, so changing it invalidates every registered
passkey. Production currently holds **0 passkey credentials and 1 user**, so
this costs nothing today and becomes a forced re-enrolment for every user once
real ones exist. It will never be cheaper than now.

### One expected origin cannot serve both platforms

With RP ID `luminavault.fyi`, the origin in `clientDataJSON` differs by
platform: web sends `https://app.luminavault.fyi`, iOS native sends
`https://luminavault.fyi`. `WEBAUTHN_RELYING_PARTY_ORIGIN` is a single string,
so no value satisfies both.

This is the same bug class as server PR #197, which changed OAuth
`audience: String` to `audiences: Set<String>` because "a web client id is
necessarily a different value". The WebAuthn origin needs the same treatment.

### WebAuthn is username-keyed, with an in-memory challenge store

`WebAuthnService` stores challenges in dictionaries keyed by username
(`registrations[username]`, `authentications[username]`). There is no
discoverable-credential support, and challenges do not survive a pod change.

Two consequences:

1. Web passkey sign-in must be username-first, matching
   `signInWithPasskey(username:)` on iOS.
2. **Passkeys work only at one API replica.** A `begin` on one pod and a
   `finish` on another will not find the challenge. `api-production` and
   `api-staging` both run 1 replica today, so it works — but this is a ceiling
   on scaling the API, not a property of it. See
   `docs/superpowers/plans/2026-05-29-p1-redis-stateless-api.md`, which covers
   the same class of state.

Not fixed here. Documented so scaling the API does not silently break sign-in.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| RP ID | `luminavault.fyi` | Only value that covers both `app.` and future subdomains; free to change at 0 credentials |
| OAuth flow | Server-side redirect | Chosen over client-side SDKs |
| Flow host | The API, not the Cloudflare Worker | Secrets stay in sealed-secrets with an existing rotation procedure; `GoogleCalendarOAuthClient` is the precedent; one implementation serves every surface |
| Passkey UX | Username-first | Matches the server as built and iOS; no server WebAuthn change beyond origins |

The flow-host decision matters most for secrets. Apple's client secret is an
ES256 JWT signed with a downloaded `.p8`, valid at most 6 months, so it needs
rotation. Putting it in the API keeps it in the sealed-secret store the estate
already operates rather than introducing Cloudflare secrets as a second store.

## Architecture

### 1. OAuth redirect, in the API

Two new routes plus one redemption endpoint:

```
GET  /v1/auth/oauth/{provider}/authorize   → 302 to provider
GET  /v1/auth/oauth/{provider}/callback    → 302 to web with a one-time code
POST /v1/auth/oauth/session                → { accessToken, refreshToken }
```

`authorize` mints `state`, `nonce` and a PKCE verifier, stores them in Valkey
(already wired as `RATE_LIMIT_STORAGE_KIND=redis`, `REDIS_URL`), and redirects.

`callback` validates `state`, exchanges the code for an id_token, verifies
signature/issuer/audience/nonce, then resolves the user through the **existing**
`oauth_identities` path — the same code the iOS `exchange` endpoint uses. A
Google account that signed up on iOS therefore lands on the same user on web.
Apple's `sub` is stable per Apple ID per team, so native and web agree.

Modelled on `Sources/App/Calendar/GoogleCalendarOAuthClient.swift`, which
already performs an `authorization_code` exchange with a sealed client secret.

### 2. Token handoff

The callback is a browser redirect and cannot hand bearer tokens to JS safely:
a URL fragment lands in history and in any `Referer` the page later emits.

Instead the callback redirects to
`https://app.luminavault.fyi/auth/callback#code=<one-time>`, and the web app
POSTs that code to `/v1/auth/oauth/session` to receive the real token pair.
The code is single-use, TTL ≤ 60s, stored in Valkey beside the state.

This keeps the durable credential out of the URL while leaving the web app's
existing bearer-token transport unchanged.

### 3. WebAuthn origins

`origin: String` becomes `origins: [String]` (an ordered, de-duplicated list,
not a `Set`), populated from a comma-separated `WEBAUTHN_RELYING_PARTY_ORIGIN`
— order is load-bearing: it decides which manager sees a ceremony first, and
therefore which manager's error is preferred when every attempt fails.
Validation becomes membership rather than equality. A single configured value
keeps behaving exactly as it does today, which is what every current
deployment has — the same compatibility property #197 relied on.

No other WebAuthn change: username-first, no resident keys, no discoverable
credentials.

### 4. Web app

- Login page gains "Continue with Google" and "Continue with Apple", each a
  plain link to `/v1/auth/oauth/{provider}/authorize`. No third-party JS.
- New `/auth/callback` route reads the fragment, redeems the code, populates
  the existing session store, and routes via `redirectAfterAuth`.
- Passkey sign-in: email field, then "Use a passkey" →
  `navigator.credentials.get()` against `webauthn/authenticate/begin|finish`.
  Base64url encode/decode is the fiddly part and gets its own tested module.

The `#code=` fragment must be stripped from the URL immediately after redeeming
(`history.replaceState`) so it does not survive in the address bar.

### 5. Configuration and DNS

New sealed secrets (per namespace — a blob is bound to namespace *and* name):

```
OAUTH_GOOGLE_WEB_CLIENT_ID
OAUTH_GOOGLE_WEB_CLIENT_SECRET
OAUTH_APPLE_SERVICES_ID
OAUTH_APPLE_TEAM_ID
OAUTH_APPLE_KEY_ID
OAUTH_APPLE_PRIVATE_KEY          # .p8 contents
```

Changed:

```
WEBAUTHN_RELYING_PARTY_ID        = luminavault.fyi
WEBAUTHN_RELYING_PARTY_ORIGIN    = https://app.luminavault.fyi,https://luminavault.fyi
OAUTH_GOOGLE_CLIENT_ID           += web client id      # comma list, per #197
OAUTH_APPLE_CLIENT_ID            += services id        # comma list, per #197
```

`luminavault.fyi` must serve
`/.well-known/apple-app-site-association` with a `webcredentials` entry for the
iOS app, or iOS passkeys break under the new RP ID. Apple also requires domain
verification for Sign in with Apple on the web, which is a separate file at the
same origin.

**Console work only a human can do:** register a Google **Web** OAuth client
(authorized redirect URI = the API callback), and an Apple **Services ID** with
its return URL and a Sign in with Apple key.

## Error handling

- Unknown/expired `state`, `nonce` mismatch, or a provider error param → redirect
  to web with an error code in the fragment; never echo provider text into the UI.
- id_token failing signature/issuer/audience → `invalidToken`, same envelope the
  existing exchange returns.
- One-time code already redeemed → 400. Single-use is enforced by deleting on
  read, not by a flag, so a replay cannot win a race.
- Passkey ceremony where the challenge is missing (pod changed, TTL elapsed) →
  a specific "please try again" rather than a generic failure, because under a
  single replica this is the observable symptom of the known ceiling.

## Security notes

- PKCE on both providers even though the API holds the secret: it costs little
  and removes code-interception as a class.
- `state` is bound to the initiating browser by an httpOnly, `SameSite=Lax`
  cookie the API sets on `authorize`, scoped to `.luminavault.fyi` so it is
  present on the callback. The callback requires cookie and `state` to agree,
  so a forged callback URL alone cannot complete a flow. (Both `app.` and
  `api.` are subdomains of the apex, which is what makes one cookie work —
  the same property that makes the RP ID change possible.)
- The redirect target is validated against an allowlist, not reflected from the
  request. `redirectAfterAuth` already rejects `//host` protocol-relative
  paths; the server-side allowlist is the backstop.
- The `.p8` never leaves the API. The Worker gains no new secret.

## Testing

- **Server:** swift-testing for state/nonce/PKCE handling, origin-set matching,
  one-time-code single use, and audience intersection. The Command Line Tools
  SDK on the dev machine has no XCTest, so the server test target cannot build
  locally — **CI is the verdict**, as recorded for this repo.
- **Web:** vitest for base64url and the callback redeem logic; Playwright for
  the login flows.
- **The OAuth round trip itself** cannot be tested honestly without a staging
  provider app. Register the Google/Apple clients against a staging redirect
  URI first and exercise it there before production.

## Known constraints carried forward

1. Passkeys require a single API replica until the challenge store moves to
   Valkey. Scaling `api-production` past 1 breaks sign-in.
2. RP ID changes invalidate credentials. After this change, the next one costs
   every user their passkey.
3. `openapi.yaml` is the contract; `make bruno-regen` must run in the same
   change set, and DTOs shared with clients belong in LuminaVaultShared.

## Out of scope

- Magic link and phone OTP on web. Both exist server-side and iOS uses them;
  neither was requested. Phone OTP also costs Twilio money for a surface that
  may not need it.
- Discoverable credentials / browser autofill passkey UX. Requires resident
  keys and a `userHandle → user` lookup, and changes an endpoint iOS uses.
- Sign in with X on web. The endpoint exists; not requested.
- Moving the WebAuthn challenge store to Valkey.

## Sequencing

Four workstreams, two of which are gated on human console work:

1. **Server** — WebAuthn origin set (smallest, independent, unblocks nothing else
   but is the lowest-risk first commit).
2. **Server** — OAuth authorize/callback/session routes behind config that
   leaves them inert until secrets exist.
3. **Infra + consoles** — register Google Web client and Apple Services ID,
   seal secrets, change RP ID/origins, publish the AASA and Apple domain
   verification files. **Blocked on the human.**
4. **Web** — buttons, callback route, passkey module.

Steps 1 and 2 can land before any console work. Step 4 can be built against
staging once step 3 exists.
