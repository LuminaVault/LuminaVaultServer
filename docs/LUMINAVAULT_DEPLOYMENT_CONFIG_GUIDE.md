# LuminaVault Deployment And Configuration Guide

This is the root handoff for agents and operators preparing LuminaVault for a real VPS backend, TestFlight, and App Store release. Treat it as the index of record; repo-specific details live in:

- `LuminaVaultServer/docs/CONFIG.md`
- `LuminaVaultServer/docs/integration.md`
- `LuminaVaultServer/docs/skills-slash-commands.md`
- `LuminaVaultClient/LuminaVaultClient/Config/README.md`
- `LuminaVaultClient/docs/TESTFLIGHT.md`
- `LuminaVaultClient/docs/chat-slash-commands.md`

Do not commit real secrets. Commit only sample files, variable names, public identifiers, and operational runbooks.

## Current Deployment Shape

LuminaVault is three deployable concerns:

| Area | Repo | Runtime | Config source |
| --- | --- | --- | --- |
| Backend API | `LuminaVaultServer` | Swift 6 Hummingbird on Linux in Docker | environment variables and `.env` |
| iOS app | `LuminaVaultClient` | SwiftUI app, TestFlight/App Store | Xcode build settings and xcconfig files |
| Shared DTOs | `LuminaVaultShared` | Swift package consumed by server/client | package version tags |

Built-in AI skills are packaged with the backend API image from `LuminaVaultServer/Sources/App/Resources/Skills/<skill-name>/SKILL.md`. Chat slash commands route through `POST /v1/skills/slash`; `/kb-compile` and `/kb-ingest` invoke the existing KB compile service, while other aliases invoke catalog skills.

The MVP production target is a single VPS running Docker Compose:

- `app`: Hummingbird API
- `postgres`: pgvector Postgres
- `valkey`: shared short-lived state for rate limits and auth/pairing records
- `hermes`: Hermes agent gateway
- `otel-collector`: telemetry fanout
- `jaeger`: local trace inspection
- host reverse proxy, normally Caddy, terminates HTTPS for `api.luminavault.com`

The backend CI already builds images to GHCR and deploys over SSH. The client CI already uses Fastlane to upload Beta builds to TestFlight.

The plugin marketplace adds an internal `plugin-runner` service. It runs reviewed WebAssembly tools as a non-root, read-only sidecar with no public port, tenant secrets, or WASI filesystem/network/process access. API calls to it use a dedicated runner token.

## Canonical Apple Identifiers

Use the existing identifiers unless a migration ticket explicitly changes them:

| Purpose | Value |
| --- | --- |
| Apple Team ID | `84X9WYBF36` |
| Production app bundle ID | `com.lumina.fernando` |
| TestFlight beta bundle ID | `com.lumina.fernando.beta` |
| Debug/dev bundle ID | `com.lumina.fernando.test` |
| Production share extension | `com.lumina.fernando.LuminaVaultShareExtension` |
| Beta share extension | `com.lumina.fernando.beta.LuminaVaultShareExtension` |
| Debug share extension | `com.lumina.fernando.test.LuminaVaultShareExtension` |
| App Group | `group.com.lumina.fernando` |
| Shared keychain access group | `$(AppIdentifierPrefix)com.lumina.fernando.shared` |

App Store Connect setup must create both app records (`com.lumina.fernando` and `com.lumina.fernando.beta`) if beta remains a separate App ID. If TestFlight is later moved under the production bundle ID, update Fastlane, profiles, APNS topic, RevenueCat app setup, and server APNS bundle config in the same change.

## Accounts And External Services

Prepare these accounts before the first production deploy:

| Service | Needed for | Values to capture |
| --- | --- | --- |
| Apple Developer | Bundle IDs, capabilities, APNS, Sign in with Apple, TestFlight | Team ID, bundle IDs, APNS key ID, App Store Connect API key, app SKUs |
| App Store Connect | App records, TestFlight, IAP metadata | API key ID, issuer ID, `.p8` key, SKU strings, app privacy answers |
| RevenueCat | Subscription products and webhook billing sync | public iOS SDK key, webhook secret, entitlement IDs, product IDs |
| Sentry | Client crash reports and backend traces/logs | client DSN, backend org/project slugs, backend auth token, auth token for dSYM upload |
| PostHog | Product analytics and backend logs | project token, host, OTel token |
| Google Cloud | Google Sign-In iOS OAuth client | iOS client ID and reversed URL scheme |
| X Developer Portal | X OAuth sign-in | OAuth client ID and redirect URI |
| Resend | Production email OTP/magic-link delivery | API key, verified sender, optional reply-to |
| Twilio | Production SMS OTP delivery | Account SID, auth token, sender number |
| LLM providers | Hosted inference fallback | provider API keys and optional base URLs |
| VPS provider | Backend hosting | host, deploy user, SSH key, DNS records |

## Backend Environment Groups

The backend reads config through `swift-configuration`. Code keys such as `hermes.gatewayUrl` map to env vars such as `HERMES_GATEWAY_URL`. Prefer the underscore-split form for new variables.

Minimum production variables:

- Postgres: `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_DATABASE`, `POSTGRES_PASSWORD`
- HTTP and deploy: `HTTP_HOST`, `HTTP_PORT`, `APP_IMAGE`, `APP_PORT`, `CORS_ALLOWEDORIGINS`
- JWT: `JWT_HMAC_SECRET`, `JWT_KID`, optional `JWT_HMAC_SECRETS`
- Hermes: `HERMES_GATEWAY_URL`, `HERMES_GATEWAY_KIND`, `HERMES_DATA_ROOT`, `HERMES_DEFAULT_MODEL`, `HERMES_DEFAULT_MANAGED_MODEL`, `HERMES_MANAGED_PROVIDER_HINT`, `HERMES_API_KEY`, `BYO_HERMES_ALLOW_TAILNET_HTTP`
- Hermes connection strategy (managed in-cluster vs self-host Tailscale vs user BYO): `LuminaVaultServer/docs/byo-hermes.md#production-hermes-connection-strategy`
- Self-improvement: `SELF_IMPROVEMENT_ENABLED=true` and `SELF_IMPROVEMENT_ECONOMY_MODEL=openrouter/free`. The server owns tenant state, weekly scheduling, pinning, reports, rollback, and SOUL approval; Hermes is used only through its existing REST inference API. Persist `/app/data` and set `VAULT_ROOT_PATH=/app/data/vaults` so custom skills and rollback material survive pod replacement.
  - Lumina defaults (not upstream Hermes): `consolidate` on, `pruneBuiltins` off, 168h cadence. Do not configure tenant curation via `hermes curator` or `~/.hermes/config.yaml`.
  - SOUL reviewer → pending proposals only; apply with `POST /v1/me/improvement/changes/{id}/approve`. Never treat Hermes profile `SOUL.md` as canonical.
  - Advisor Path B vs Path A cheat sheet: `LuminaVaultServer/docs/CONFIG.md` (Self-improvement). Agent rule: `.cursor/rules/hermes-self-improvement.mdc`.
- Multimodal ingestion: `INGESTION_PUBLIC_BASE_URL=https://api.luminavault.com` enables short-lived, tokenized source downloads for BYO Hermes. It must be the externally reachable API origin and must use HTTPS outside development.
- Hermes image source: `LuminaVault/LuminaVaultHermesAgent` publishes
  `ghcr.io/luminavault/luminavault-hermes-agent`. The server's
  `docker/hermes.Dockerfile` pins that image by digest and adds the bundled
  LuminaVault skills/Mnemosyne layer. The fork advertises and implements
  `/v1/ingestions`, remote source URLs, supported MIME patterns, and maximum
  source bytes. Never replace the digest with upstream `latest` without
  revalidating those capabilities.
- Vault: `VAULT_ROOT_PATH`
- Rate limiting and short-lived state: `RATE_LIMIT_STORAGE_KIND=redis`, `REDIS_URL=redis://valkey:6379`
- Secret encryption: `LV_SECRET_MASTER_KEY`, `LV_ENVIRONMENT`
- APNS: `APNS_ENABLED`, `APNS_BUNDLE_ID`, `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY_PATH`, `APNS_ENVIRONMENT`
- OAuth: `OAUTH_APPLE_CLIENTID`, `OAUTH_GOOGLE_CLIENTID`, `OAUTH_X_CLIENTID`
- WebAuthn/passkeys: `WEBAUTHN_ENABLED`, `WEBAUTHN_RELYINGPARTYID`, `WEBAUTHN_RELYINGPARTYNAME`, `WEBAUTHN_RELYINGPARTYORIGIN`
- RevenueCat: `REVENUECAT_WEBHOOK_SECRET`, `BILLING_ENFORCEMENT_ENABLED`
- Observability: `OTEL_ENABLED`, `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `POSTHOG_OTEL_TOKEN`, `SENTRY_BASE_URL`, `SENTRY_ORG_SLUG`, `SENTRY_PROJECT_SLUG`, `SENTRY_AUTH_TOKEN`, `SENTRY_ENVIRONMENT`, `SENTRY_RELEASE`. Kubernetes API pods must use the standard OTLP endpoint variable with `http://alloy.observability.svc.cluster.local:4317`; `OBS_OTLP_ENDPOINT` is not consumed by the Swift server. Use `OTEL_SERVICE_NAME=luminavault-api-staging` in staging and `OTEL_SERVICE_NAME=luminavault-api-production` in production so Grafana metrics and Tempo traces cannot mix environments. Alloy forwards traces to Tempo and OTLP metrics to Mimir.
- Email/SMS: `EMAIL_KIND`, `EMAIL_RESEND_API_KEY`, `EMAIL_FROM_ADDRESS`, `TEAM_INVITE_BASE_URL`, `SMS_KIND`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER`. Production deploys read `TEAM_INVITE_BASE_URL` from the required GitHub Actions repository variable of the same name; its canonical value is `https://app.luminavault.com`.
- Provider keys: `LLM_PROVIDER_*`, `VISION_EMBED_*`, `TRANSCRIBE_*`, `TTS_*`, `GEMINI_API_KEY`
- Managed inference: the backend owns the effective route. Set `HERMES_DEFAULT_MANAGED_MODEL=deepseek/deepseek-v4-flash` and fund it with `LLM_PROVIDER_OPENROUTER_APIKEY`; iOS and web must render the route returned by `/v1/me/preferences/llm` rather than hard-code a model. Managed PUTs are canonicalized server-side, and existing persistent Cerberus profiles must be reconciled after a model change.
- Cerberus routing: `CERBERUS_EXECUTION_MODE=active`, `CERBERUS_PARALLEL_ENABLED=false`. Keep parallel execution off until its multi-provider cost is intentionally enabled; `CERBERUS_ENSEMBLES_ENABLED` remains a temporary fallback when the new variable is absent. Set execution mode to `shadow` to roll back to legacy routing without deleting profiles.
- Cerberus Studio: `CERBERUS_STUDIO_ENABLED=true`, `CERBERUS_STUDIO_WORKER_COUNT=4`, `CERBERUS_STUDIO_GLOBAL_DAILY_USD_MICROS=10000000`, and `CERBERUS_STUDIO_GLOBAL_MONTHLY_USD_MICROS=100000000`. The platform-funded pool uses `LLM_PROVIDER_OPENROUTER_APIKEY`; the legacy `OPENROUTER_API_KEY` name is accepted only as a compatibility fallback. Without either key, users may browse Studio but managed executions pause as provider unavailable—`openrouter/free` still requires the platform key. Exhausted managed allowances and failed managed-provider calls retry `openrouter/free` once before pausing. Pro is capped at $0.20/run, $0.50/day, and $2/month with one active run and 60-minute schedules. Ultimate is capped at $1/run, $2/day, and $8/month with three active runs and five-minute schedules. Ultimate BYOK calls do not debit managed allowance. Keep an OpenRouter key/provider credit limit at or below the platform global monthly ceiling as a second, provider-side guardrail. OpenRouter's published free-tier policy (verified 2026-07-18) allows zero-cost `:free`/`openrouter/free` calls with a valid, non-negative-balance key, but accounts that have purchased less than $10 in credits are limited to 50 free requests/day and 20 requests/minute; purchasing at least $10 raises the daily free allowance to 1,000. A negative balance can return 402 even for free models. Treat an unfunded account as beta/failover capacity, not a paid-tier production SLA.
- Database migrations: keep `FLUENT_AUTOMIGRATE=false` in production. The server deploy workflows run the new image's `app migrate` command after PostgreSQL is healthy and before replacing the live API. Migration failure aborts the deployment. Studio requires M109; only additive/backward-compatible migrations may use the automatic last-known-good image rollback path.
- Hybrid execution: `HYBRID_EXECUTION_ENABLED=true` enables prepare/commit, stable incremental local-memory sync, and synchronized routing preferences. `LOCAL_EXECUTION_TOOL_BROKER_ENABLED=true` enables the tenant-scoped read-only broker; its initial allow-list contains only `memory_search`, and every invocation must belong to an active, unexpired prepared execution. Set it to `false` for an immediate broker kill switch. Local endpoint URLs and keys remain device/browser configuration.
- Knowledge graph: `KNOWLEDGE_GRAPH_WORKER_ENABLED=true` by default so new ingestion memories automatically produce claim/entity/event nodes and evidence-backed connections. Set it to `false` to pause extraction without removing graph reads or review history. `KNOWLEDGE_GRAPH_MODEL_EXTRACTION_ENABLED=false` controls the staged, routed-model adjudication pass for ambiguous cross-memory relationships; enable it only after reviewing provider cost and suggestion precision.
- Marketplace runner: `PLUGIN_RUNNER_URL=http://plugin-runner:8090`, a random `PLUGIN_RUNNER_TOKEN` of at least 32 characters, `PLUGIN_ARTIFACT_ROOT=/app/data/plugin-artifacts`, and an independent random `PLUGIN_ARTIFACT_SIGNING_KEY` of at least 32 characters. The artifact root must be persistent and writable only by the API. Never reuse the runner, artifact-signing, JWT, Hermes, or admin secrets.

When the managed Hermes model changes, run `make hermes-sync-context` in `LuminaVaultServer` so Hermes' `context_length` override is resolved from provider metadata. Use `HERMES_DEFAULT_MANAGED_CONTEXT_LENGTH` only as a fallback for providers that cannot expose model context metadata.

Production must never set `PHONE_FIXED_OTP` or `MAGIC_FIXED_OTP`.

## Client Build Configuration

The client should use committed `.xcconfig.sample` files and gitignored real `.xcconfig` files. Required build-time values:

- `API_BASE_URL`: hosted backend URL, normally `https://api.luminavault.com`
- `APPLE_SERVICE_ID`: Sign in with Apple service or app audience expected by the server
- `GID_CLIENT_ID`: Google iOS OAuth client ID; must match server `OAUTH_GOOGLE_CLIENTID`
- `REVERSED_CLIENT_ID`: Google reversed client ID URL scheme
- `X_CLIENT_ID`: X OAuth client ID; must match server `OAUTH_X_CLIENTID`
- `X_REDIRECT_URI`: callback URI registered in X Developer Portal
- `LV_RC_API_KEY`: RevenueCat public iOS SDK key
- `POSTHOG_PROJECT_TOKEN`, `POSTHOG_HOST`
- `SENTRY_DSN`
- `KEYCHAIN_ACCESS_GROUP`: shared app/extension access group used for the auth token, normally `$(AppIdentifierPrefix)com.lumina.fernando.shared`
- `WEBAUTHN_RP_ID`: passkey relying-party host; must equal server `WEBAUTHN_RELYINGPARTYID` and the app's `webcredentials:<host>` associated-domain entitlement
- `LV_TERMS_URL`, `LV_PRIVACY_URL`

Hybrid execution settings are runtime user preferences, not build secrets. iOS stores local endpoint credentials in Keychain; web stores them in encrypted IndexedDB. Private-profile prompts must not be sent to the API or telemetry.

The Info.plist used by the app must include Google URL schemes and all public runtime values above. The app and share extension Info.plists both read `API_BASE_URL` and `KEYCHAIN_ACCESS_GROUP` from build settings. The app and extension must keep APNS, Sign in with Apple, HealthKit, background delivery, App Groups, and Keychain Sharing capabilities aligned with the Apple Developer App IDs and provisioning profiles. Passkeys additionally require Associated Domains on the host app App ID and an AASA `webcredentials` block served by `WEBAUTHN_RP_ID`.

## Share Extension Capture

The iOS share extension is part of the client app bundle and must be signed with the same team as the host app.

Required Apple capabilities:

- Host app: App Groups `group.com.lumina.fernando`, Keychain Sharing `$(KEYCHAIN_ACCESS_GROUP)`, Push Notifications, Sign in with Apple, HealthKit, background delivery.
- Share extension: App Groups `group.com.lumina.fernando`, Keychain Sharing `$(KEYCHAIN_ACCESS_GROUP)`.

Capture behavior:

- URL shares from Safari, Mail, Notes, Chrome, and other apps call `POST /v1/capture/safari` directly when the extension can read a shared keychain access token.
- Plain text shares are uploaded as generated Markdown files through `POST /v1/vault/files`, then mirrored through memory upsert for search and memo continuity.
- Image shares are uploaded through `POST /v1/vault/files` and mirrored through memory upsert. There is no current `/v1/capture/photo` endpoint contract.
- If the extension is offline, unauthenticated, or the request fails, it writes a pending capture into the App Group queue. The main app drains that queue on launch and foreground.
- Last-used Space selection is stored in App Group `UserDefaults` so the extension can preselect it even when the host app is killed.

Do not add Sentry or PostHog SDKs to the extension unless a separate memory-budget ticket approves it. Extension observability should stay lightweight.

## RevenueCat And StoreKit

Use RevenueCat as the client purchase source and the server as the entitlement source.

Required RevenueCat setup:

- Create one RevenueCat project for LuminaVault.
- Add the iOS app bundle IDs that will ship purchases.
- Create entitlements that match server tiers, for example `plus` and `pro`.
- Create App Store products/subscriptions and attach them to offerings.
- Set RevenueCat webhook URL to `https://api.luminavault.com/v1/billing/revenuecat`.
- Store the webhook shared secret in `REVENUECAT_WEBHOOK_SECRET`.
- Store the iOS public SDK key in `LV_RC_API_KEY`.

Suggested SKU naming:

- App SKU: `luminavault-ios`
- Beta/internal SKU: `luminavault-ios-beta`
- Monthly Plus product: `lv_plus_monthly`
- Annual Plus product: `lv_plus_annual`
- Monthly Pro product: `lv_pro_monthly`
- Annual Pro product: `lv_pro_annual`

If product IDs change, update RevenueCat, App Store Connect, client paywall assumptions, server billing docs, and any App Review notes together.

## APNS

APNS has a server side and a client side.

Server:

- Mount the `.p8` key at `LuminaVaultServer/secrets/apns-key.p8` in production.
- Set `APNS_PRIVATE_KEY_PATH=/app/secrets/apns-key.p8`.
- Set `APNS_BUNDLE_ID` to the app bundle receiving pushes.
- Set `APNS_ENVIRONMENT=production` for TestFlight/App Store builds.

Client:

- Enable Push Notifications on the App ID.
- Keep `aps-environment` in entitlements.
- Register device tokens only after authentication, which the app already does.
- Confirm the server `/v1/devices` endpoint succeeds after first login.
- Workflow pushes use category `workflow` with `workflowID`, `runID`, `state`, and a `luminavault://studio/runs/<runID>` deep link. Test approval, completion, paused, and failed notifications after deploying the M109 migration.

## OAuth

Apple:

- Enable Sign in with Apple on the App ID.
- Ensure server `OAUTH_APPLE_CLIENTID` matches the `aud` in the iOS identity token.
- Keep `com.apple.developer.applesignin` entitlement set to `Default`.

Google:

- Create an iOS OAuth client in Google Cloud.
- Put the iOS client ID in both client `GID_CLIENT_ID` and server `OAUTH_GOOGLE_CLIENTID`.
- Put the reversed ID in client `REVERSED_CLIENT_ID`.
- Confirm the generated app Info.plist includes the reversed URL scheme.

X:

- Create an OAuth 2.0 app in X Developer Portal.
- Put the client ID in both client `X_CLIENT_ID` and server `OAUTH_X_CLIENTID`.
- Put the callback URI in client `X_REDIRECT_URI`.
- Confirm the callback URI is registered exactly in the X app.

## CI/CD Secrets

Backend GitHub environment secrets:

- `SERVER_HOST`
- `SERVER_USER`
- `SERVER_SSH_KEY`
- `PLUGIN_RUNNER_TOKEN`
- `PLUGIN_ARTIFACT_SIGNING_KEY`
- `LLM_PROVIDER_OPENROUTER_APIKEY`
- `POSTHOG_OTEL_TOKEN`
- `SENTRY_BASE_URL`
- `SENTRY_ORG_SLUG`
- `SENTRY_PROJECT_SLUG`
- `SENTRY_AUTH_TOKEN`
- Optional: `SENTRY_ENVIRONMENT`, `SENTRY_RELEASE`

Backend server-side `.env.production` must contain all runtime secrets, not just CI secrets.

Cerberus Studio release ordering is strict: publish and tag `LuminaVaultShared` 3.17, resolve and commit the server/client package locks, deploy the server so M109 is applied, deploy the web editor, and only then ship the iOS build. A clean CI checkout cannot consume unpublished sibling-package changes.

Client GitHub secrets:

- `MATCH_GIT_URL`
- `MATCH_PASSWORD`
- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_API_KEY_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_KEY`
- `FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD`
- `SENTRY_AUTH_TOKEN` for dSYM uploads if the Sentry Fastlane action is used

Client CI should pass non-secret public config as build settings or use checked-in sample xcconfigs copied to real files by the workflow. Private `.p8` keys and match passwords remain secrets.

## Release Readiness Checklist

- Backend deploys from GHCR to the VPS and `/health` returns `ok` over HTTPS.
- Caddy or another reverse proxy serves `https://api.luminavault.com`.
- `.env.production` has no placeholder values.
- Postgres backup and restore drill has been tested.
- Marketplace packages and the `plugin-artifacts` volume are included in backup/restore drills before WASM publishing is enabled.
- OTel collector exports to PostHog and Sentry.
- APNS device registration succeeds from a TestFlight build.
- RevenueCat purchase, restore, and webhook entitlement sync are verified.
- Apple, Google, and X sign-in all complete and server exchange endpoints accept tokens.
- TestFlight build uploads from CI and includes dSYMs in Sentry.
- App Store Connect has privacy answers, encryption answer, SKUs, IAP metadata, support URL, privacy URL, and review notes.

## Deployment & Runtime Status

Last verified: **2026-07-22**. Canonical public API host: **`api.luminavault.fyi`**
(legacy `*.luminavault.com` references may still appear in older client xcconfig
samples). **`GET /health/deep` is not implemented** on LuminaVaultServer — use
`GET /health` for liveness and Hermes `GET /v1/models` (Bearer) for gateway depth.

### Live probes (2026-07-22)

| Check | Result |
| --- | --- |
| `GET https://api.luminavault.fyi/health` | `200` / body `ok` |
| `GET https://api-staging.luminavault.fyi/health` | `200` / body `ok` |

Hermes in-cluster probes require cluster credentials (`kubectl` + sealed `hermes-env`).

### Cross-repository verification matrix

| Check | Server | Infra | iOS | Web | Shared |
| --- | --- | --- | --- | --- | --- |
| Public liveness `GET /health` | smoke in `deploy.md` | cutover runbook | Release API URL | Settings probe | — |
| CORS allows web origin | `CORS_ALLOWEDORIGINS` | `api-env` sealed secret | — | README + PHASED-PLAN | — |
| BYOK missing-key UX | `403 byok_keys_required` + CTA | — | Chat recovery actions | Chat recovery actions | OpenAPI `StructuredAPIErrorEnvelope` |
| LLM BYOK tier | any chat-capable tier | — | Intelligence (no Ultimate gate) | Intelligence (no Ultimate gate) | `LLMBrainMode.byok` |
| Hermes REST `api_server` | Compose + k8s manifests | `apps/hermes/hermes.yaml` | BYO Hermes settings | Settings → Hermes | — |
| Managed Hermes URL | `HERMES_GATEWAY_URL` | `api-env` + cluster DNS | — | — | — |
| OpenAPI contract | `openapi.yaml` source | — | DTO parity | `npm run gen:api` | `LuminaVaultShared` tags |
| Observability | OTEL env | Alloy + grafana-cloud | Sentry dSYM | Sentry DSN | — |

### Open operational items

- **Incident 2026-07** (`LuminaVaultServer/docs/runbooks/incident-2026-07.md`): status OPEN until rotation/decommission checklist completes.
- **k3s cutover**: staging live; production Compose on `167.233.30.48` until DNS flip (`LuminaVaultInfra/docs/runbook-cutover.md`).
- **Legacy Hermes VPS** (`78.46.192.73`): decommission when confirmed idle — superseded by in-cluster Hermes.
- **Reseal `api-env`**: set `HERMES_GATEWAY_KIND=logging` in staging/production when rotating secrets (templates updated in `secrets/*/api-env.example.yaml`).
