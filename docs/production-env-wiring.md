# Production Env Wiring — Pre-Launch TODO

Status as of 2026-06-08. These are the **production environment variables that are not yet set** and the decisions still open before TestFlight / App Store. None are code bugs — they are deploy-time wiring. Set them as GitHub repo secrets (the `prod.yml` workflow upserts secrets into `.env.production` on the VPS) unless noted as on-box only.

---

## 1. Email OTP delivery — **REQUIRED, not set**

Magic-link / email OTP login is **silently broken** until this is set. With `EMAIL_KIND` unset, the server falls back to `logging` (OTPs only print to container stderr, never reach the user → nobody can sign in by email).

Set these GitHub secrets:

| Secret | Value |
|---|---|
| `EMAIL_KIND` | `resend` |
| `EMAIL_RESEND_APIKEY` | Resend API key (`re_…`) |
| `EMAIL_FROM_ADDRESS` | a sender on a **domain verified in Resend** (e.g. `lumina@luminavault.fyi`) |
| `EMAIL_REPLY_TO` | optional reply-to |

Steps: create a Resend account → verify the `luminavault.fyi` sending domain (DNS records) → mint an API key → set the 3 secrets above.

## 2. SMS / phone OTP — **REQUIRED if phone auth is offered, not set**

Same failure mode: `SMS_KIND` unset → `logging` → phone OTP never delivered.

| Secret | Value |
|---|---|
| `SMS_KIND` | `twilio` |
| `TWILIO_ACCOUNT_SID` | Twilio SID |
| `TWILIO_AUTH_TOKEN` | Twilio auth token |
| `TWILIO_FROM_NUMBER` | a Twilio-owned sending number (E.164) |

If phone auth is **not** in the launch scope, leave unset — but then disable/hide the phone sign-in path in the client so users don't hit a dead flow.

> **Note — these are AUTH secrets, not Hermes gateways.** `EMAIL_KIND`/`SMS_KIND` (Resend/Twilio above) deliver **login OTPs**. They are unrelated to the Hermes **Email** and **SMS messaging gateways** (chatting with the agent over email/SMS), which are configured per-tenant from the iOS app and activate via different env-vars inside each tenant's Hermes container. See §7 for gateway coverage.

## 3. Embedding provider — **VERIFY, likely a stub in prod**

Code/`.env.example` default is `EMBEDDING_PROVIDER=deterministic` (hash-based fake vectors). If prod inherits that default, **semantic search and chat grounding return garbage relevance**. `docker-compose.production.yml` does not pin a real provider, so it inherits the code default.

Set a real provider + key:

| Secret | Value |
|---|---|
| `EMBEDDING_PROVIDER` | `openai` \| `nomic` \| `hermesLocal` |
| (provider key) | e.g. `OPENAI_API_KEY` for the `openai` provider |

Verify after deploy: capture a note, ask a related question in chat, confirm the recall is topically relevant (not random).

## 4. `.env.production` placeholder sweep

After setting the above, confirm no leftover defaults/placeholders on the box:

```bash
grep -rE "REPLACE_WITH|change-me|deterministic|:-logging|:- *$" /opt/luminavault/.env.production
```
Expect zero hits. Confirm the `:?required` vars are all present: `POSTGRES_PASSWORD`, `JWT_HMAC_SECRET`, `HERMES_API_KEY`, `CORS_ALLOWED_ORIGINS`.

---

## 5. Open decision — BYO-Hermes HTTPS

`.env.example:130` `BYO_HERMES_REQUIRE_HTTPS=false` — lets a user point BYO-Hermes at a plaintext `http://` gateway (auth header sent in cleartext). Private ranges already blocked (`BYO_HERMES_ALLOW_PRIVATE=false`).

**Decide:** set `BYO_HERMES_REQUIRE_HTTPS=true` as the managed-prod default (recommended for the hosted product), or keep `false` and document that it's intended for self-host only. Self-host users can still override.

---

## 6. Optional hardening (deferred — not applied)

`docker-compose.production.yml` currently defaults `EMAIL_KIND`/`SMS_KIND` to `logging`, so a misconfigured deploy half-works silently instead of failing loud. Once sections 1–2 are set and proven, consider switching the compose defaults to fail-fast so future deploys refuse to boot when these are missing:

```yaml
EMAIL_KIND: ${EMAIL_KIND:?EMAIL_KIND required (set to 'resend' in prod)}
SMS_KIND:   ${SMS_KIND:?SMS_KIND required (set to 'twilio' in prod)}
```

**Not applied yet** — would block deploys until the secrets above exist. Apply only after sections 1–2 are confirmed live.

---

## 7. Hermes messaging gateway coverage — **5 of 22 wired**

Hermes (per [Nous messaging docs](https://hermes-agent.nousresearch.com/docs/user-guide/messaging)) supports **22** messaging platforms. Our `HermesGatewayCatalog.swift` exposes **5**. The per-tenant Hermes image already ships every adapter — activation is just the presence of each platform's token env-var in the tenant `.env`. So "adding" a gateway = (1) add the `HermesGatewayID` case in `LuminaVaultShared`, (2) add a catalog `Entry` (fields) + `envVars` mapping in `HermesGatewayCatalog.swift`. The iOS detail view renders fields generically — **no client code needed** for credential gateways.

### Have (5)
Telegram · Discord · Slack · Email · WhatsApp (QR pairing)

### Missing (17)

**Tier A — Western / high-value (worth adding):**
| Platform | Adds | Notes |
|---|---|---|
| **Signal** | `SIGNAL_*` + `SIGNAL_ALLOWED_USERS` | needs `signal-cli` + a registered number in the container; not pure-credential (infra like WhatsApp) |
| **BlueBubbles (iMessage)** | server URL + password | needs a user-run BlueBubbles macOS server; credential form, but external dependency |
| **Microsoft Teams** | app id / app password / `TEAMS_ALLOWED_USERS` (AAD object ids) | enterprise; Azure bot registration |
| **Google Chat** | service-account JSON | enterprise/Workspace |
| **Matrix** | homeserver + access token / `MATRIX_ALLOWED_USERS` | decentralized; easy credential form |
| **LINE** | channel access token + secret | big in JP/TW |
| **ntfy** | topic + server url | push-notify only (no rich features); trivial to add |
| **Home Assistant** | HA url + token | smart-home control toolset |
| **Mattermost** | bot token / `MATTERMOST_ALLOWED_USERS` | self-host Slack alt |
| **SMS** | Twilio SID/token/number + `SMS_ALLOWED_USERS` | **reuses the same Twilio account as auth §2** — chat-with-agent over SMS |

**Tier B — China / regional (defer unless targeting those markets):**
DingTalk · Feishu/Lark · WeCom · WeCom Callback · Weixin (WeChat) · QQ · Yuanbao

### Recommendation
For a Western consumer launch the current 5 cover the mainstream. Highest-ROI next adds (pure credential forms, no extra infra): **Matrix, ntfy, Microsoft Teams, Google Chat, LINE**. **Signal** and **iMessage** are high-demand but need per-tenant external infra (signal-cli / BlueBubbles host) — treat as their own mini-projects like WhatsApp QR. **SMS gateway** is cheap since Twilio is already in the stack for auth. Not a TestFlight blocker — purely product surface area.

---

## Verify-once gates (already documented in `testflight-launch.md` / deploy guide)

- `/health` → `ok` over HTTPS at the prod host.
- APNS device registration from a real TestFlight build.
- RevenueCat sandbox purchase + restore + webhook → server entitlement sync.
- OAuth (Apple, Google, X) full round trip incl. server token exchange.
- dSYMs → Sentry; OTel → PostHog + Sentry.
- Postgres backup/restore drill (the `backup` sidecar needs one-time age + rclone setup on the VPS).
- App Store Connect: encryption-export answer, privacy labels, IAP SKUs, support + privacy URLs, review notes + demo account.
