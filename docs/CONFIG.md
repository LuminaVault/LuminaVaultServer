# Configuration & Environment Variables

LuminaVaultServer reads configuration through Apple's [swift-configuration](https://github.com/apple/swift-configuration) framework. Keys are spelled `camelCase.dot.path` in code (`ConfigKey("hermes.gatewayUrl")`), and the framework resolves them against env vars in `SCREAMING_SNAKE_CASE` (so `hermes.gatewayUrl` ↔ `HERMES_GATEWAY_URL`).

## Sources of truth

| File | Purpose |
| --- | --- |
| `.env.example` | **Canonical contract.** Every variable the server reads should appear here (with a safe default or an explicit `# REQUIRED` comment). Committed to git — do not put secrets in this file. |
| `.env` | Local-dev copy. Git-ignored. Created by `cp .env.example .env`. |
| `docker-compose.yml` | Dev compose stack. References `${VAR:-default}` so an unset var falls back to the default. |
| `docker-compose.production.yml` | Prod compose stack. Uses `${VAR:?required}` for must-haves (`POSTGRES_PASSWORD`, `JWT_HMAC_SECRET`, `CORS_ALLOWEDORIGINS`) so the container fails fast with a clear error if the operator forgot one. |
| `otel-collector-config.yaml` | Local OTel fanout: traces to Jaeger, logs to PostHog, metrics to debug. |
| `otel-collector-config.production.yaml` | Production OTel fanout: traces/logs to Sentry, logs to PostHog, traces to Jaeger, metrics to debug. |

`.env.example` is the contract; the compose files are the runtime wiring. When you add a new `ConfigKey(...)` read in code, you must update **both** files in the same change.

## Naming convention

- Code reads `ConfigKey("foo.barBaz")`.
- Env var spelling is `FOO_BAR_BAZ` (dot → underscore, camelCase split on word boundary).
- The Configuration framework is lenient and will match both `FOO_BAR_BAZ` and `FOO_BARBAZ`. Prefer the underscored form for new keys — grep-able and consistent with the existing `.env.example`. Existing compose entries (`OAUTH_APPLE_CLIENTID`, `HERMES_GATEWAYURL`) use the concatenated form for legacy reasons; both styles work, but new code should standardise on the split form.

## Required in production

The prod compose declares these as `${VAR:?required}` — container start fails if unset:

- `POSTGRES_PASSWORD`
- `JWT_HMAC_SECRET` (32+ chars; rotate annually — see "JWT key rotation" below)
- `CORS_ALLOWEDORIGINS` (comma-separated list, no spaces inside URLs)
- `POSTHOG_OTEL_TOKEN` (production compose requires it for backend log export)
- `SENTRY_ORG_SLUG`, `SENTRY_PROJECT_SLUG`, `SENTRY_AUTH_TOKEN` (production compose requires them for backend Sentry export)
- `HERMES_API_KEY` (32+ bytes; gates the central Hermes gateway — see "Hermes gateway authentication" below)

Everything else has a safe default appropriate for a single-tenant deploy. Empty `*_APIKEY` values keep the matching provider unregistered (endpoint returns 503) — that is the intended behaviour, not an error.

### Plugin marketplace and WASM runner

| Variable | Required | Default | Purpose |
| --- | --- | --- | --- |
| `PLUGIN_RUNNER_URL` | When WASM execution is enabled | `http://plugin-runner:8090` | Internal runner base URL. Never expose it publicly. |
| `PLUGIN_RUNNER_TOKEN` | Production | none | Random API-to-runner bearer secret, minimum 32 characters. |
| `PLUGIN_ARTIFACT_ROOT` | When publishing WASM | `/app/data/plugin-artifacts` | Persistent reviewed-artifact cache mounted only into the API. |

The runner must remain non-root with a read-only root filesystem, all Linux
capabilities dropped, `no-new-privileges`, PID/memory/CPU limits, and no host
port. Guest modules receive no WASI environment, filesystem, socket, clock, or
process imports. Rotate `PLUGIN_RUNNER_TOKEN` by restarting the API and runner
in the same deployment.

### Hermes gateway authentication

`HERMES_API_KEY` (32+ bytes; `openssl rand -hex 32`) is shared between two containers:

- The `hermes` service reads it as `API_SERVER_KEY` and enforces Bearer auth on `:8642`. Without it the central `api_server` refuses to bind `0.0.0.0`.
- The `app` (Hummingbird) container reads it as `HERMES_APIKEY` and attaches `Authorization: Bearer …` to every outbound call (`HermesGatewayAdapter`, `URLSessionHermesChatTransport`, `DefaultHermesLLMStreamService`).

If `LV_ENVIRONMENT` is anything other than `dev` and the key is unset, the Hummingbird app refuses to boot (HER-186 fail-closed). In dev (`LV_ENVIRONMENT=dev`, the default) an empty key is allowed and logs a warning — outbound calls go unauthenticated, which is fine against a dev Hermes that also runs without `API_SERVER_KEY`.

Bootstrap and rotation:

```sh
make hermes-bootstrap        # generates a fresh key into .env
```

To rotate: regenerate the key, update the env-secret store, and restart both containers in the same change so they never disagree. Dedicated rotation tooling is tracked separately.

### Sentry backend telemetry

The server does not use the Apple-platform Sentry SDK. Backend telemetry flows through OpenTelemetry:

1. The app emits OTel traces/logs to the `otel-collector`.
2. Production compose mounts `otel-collector-config.production.yaml`.
3. The collector routes traces/logs to Sentry using the OTel Collector `sentry` exporter.

Required production values:

- `SENTRY_BASE_URL=https://sentry.io` (or the region/self-hosted base URL)
- `SENTRY_ORG_SLUG=...`
- `SENTRY_PROJECT_SLUG=luminavault-server`
- `SENTRY_AUTH_TOKEN=...` with at least `org:read` and `project:read`
- `SENTRY_ENVIRONMENT=production`
- `SENTRY_RELEASE=<git-sha-or-version>`

The Sentry exporter routes by OTel `service.name`. The production config maps both `luminavault` and `LuminaVaultServer` to `SENTRY_PROJECT_SLUG` so current app settings keep working while the naming is cleaned up.

### BYO Hermes and encrypted user credentials

These features are disabled until `LV_SECRET_MASTER_KEY` is set:

- `/v1/settings/hermes`
- per-user LLM provider credentials
- XAI OAuth container flow
- Hermes messaging gateway configuration

Generate the key with:

```sh
openssl rand -base64 32
```

Production values:

- `LV_SECRET_MASTER_KEY=<32-byte-base64-secret>`
- `LV_ENVIRONMENT=production`
- `BYO_HERMES_ALLOW_PRIVATE=false`
- `BYO_HERMES_REQUIRE_HTTPS=false`

Set `BYO_HERMES_ALLOW_PRIVATE=true` only for local/dev networks where private IP gateway URLs are intentional.

`BYO_HERMES_REQUIRE_HTTPS` defaults to `false`, so self-hosters may point at a plain-`http://` or bare-IP Hermes (the iOS client shows an insecurity warning). Set it to `true` to force TLS and reject `http://` at config time. Private/loopback/link-local/metadata targets stay blocked regardless of this flag (controlled by `BYO_HERMES_ALLOW_PRIVATE`).

See **[byo-hermes.md](byo-hermes.md)** for the end-user guide to exposing a self-hosted Hermes (nginx + HTTPS, Cloudflare Tunnel, SSRF behaviour, troubleshooting).

### Per-tenant Hermes containers

The XAI OAuth and Grok proxy surfaces can spin up per-tenant Hermes containers. Keep these defaults unless the VPS topology changes:

- `HERMES_PER_TENANT_IMAGE=nousresearch/hermes-agent:latest`
- `HERMES_PER_TENANT_NETWORK=luminavault-hermes-net`
- `HERMES_PER_TENANT_DATA_ROOT_BASE=/app/data/hermes-tenants`
- `HERMES_PER_TENANT_PORT_RANGE_START=9000`
- `HERMES_PER_TENANT_PORT_RANGE_END=9500`
- `HERMES_PER_TENANT_IDLE_TTL_SECONDS=1800`
- `DOCKER_BINARY_PATH=/usr/bin/docker`

The app container needs access to the Docker socket before these flows can work on a VPS. Do not mount the socket casually; document the host-level security decision in the deployment PR.

### App Store dependent services

These server variables must match iOS/App Store configuration:

| Variable | Must match |
| --- | --- |
| `APNS_BUNDLE_ID` | Bundle ID receiving pushes (`com.lumina.fernando` for production) |
| `APNS_TEAM_ID` | Apple Team ID (`84X9WYBF36`) |
| `APNS_KEY_ID` | Apple Developer APNS auth key ID |
| `APNS_ENVIRONMENT` | `production` for TestFlight/App Store |
| `OAUTH_APPLE_CLIENTID` | Apple identity token audience |
| `OAUTH_GOOGLE_CLIENTID` | iOS Google OAuth client ID in the app |
| `OAUTH_X_CLIENTID` | X OAuth client ID in the app |
| `REVENUECAT_WEBHOOK_SECRET` | RevenueCat webhook shared secret |

If any of these change, update the iOS xcconfig, Apple Developer/App Store Connect, provider dashboard, and this server config in the same change.

### Provider keys

Deployment-level LLM keys are optional fallbacks. Empty values mean the provider stays unavailable unless a user supplies their own encrypted credential:

- OpenAI-compatible: `LLM_PROVIDER_OPENAI_APIKEY`, `LLM_PROVIDER_OPENROUTER_APIKEY`, `LLM_PROVIDER_XAI_APIKEY`, `LLM_PROVIDER_TOGETHER_APIKEY`, `LLM_PROVIDER_GROQ_APIKEY`, `LLM_PROVIDER_FIREWORKS_APIKEY`, `LLM_PROVIDER_DEEPINFRA_APIKEY`, `LLM_PROVIDER_DEEPSEEKDIRECT_APIKEY`
- Anthropic: `LLM_PROVIDER_ANTHROPIC_APIKEY`
- Ollama: `LLM_PROVIDER_OLLAMA_BASEURL`
- Vision: `VISION_EMBED_PROVIDER_COHERE_APIKEY`
- Speech-to-text: `TRANSCRIBE_PROVIDER_GROQ_APIKEY`
- TTS: `LLM_PROVIDER_OPENAI_APIKEY` with `TTS_PROVIDER=openai`
- Gemini fallback: `GEMINI_API_KEY`

### Cerberus model router

- `CERBERUS_EXECUTION_MODE`: `active` evaluates the resolved user, Space, or Job profile; any other value retains the legacy preference router for rollback.
- `CERBERUS_ENSEMBLES_ENABLED`: enables profile actions that run models in parallel and synthesize their outputs. Defaults to `false` because an ensemble can multiply provider usage.
- `CERBERUS_PARALLEL_ENABLED`: master gate for Ultimate-tier Best-of-N, Consensus, Debate, Specialist, playground, and chat multi-model execution. Defaults to `false`; when absent the server falls back to `CERBERUS_ENSEMBLES_ENABLED` for one-release compatibility.

Profiles, bindings, budgets, routing attempts, and monthly usage are stored in PostgreSQL. Provider prices in the router catalog are estimates used for routing and budget reservation; actual provider invoices remain authoritative.

#### Managed Hermes output cap (`model.max_tokens`)

`model.max_tokens` in `data/hermes/config.yaml` limits tokens generated PER
reply. It is independent of `context_length` (the input window). It is currently
`1024`.

Why it's set: OpenRouter reserves credits for `(prompt_tokens + max_tokens)`
before generating. An unset cap makes Hermes request the model's native ceiling
(8192 for qwen-2.5-72b), and on a low balance OpenRouter returns HTTP 402
(*"requires more credits, or fewer max_tokens"*) → the assistant reply is blank.

To raise the cap later:

1. Ensure the OpenRouter balance covers it. Rough rule:
   `affordable_output ≈ (balance / model_price_per_output_token) − prompt_tokens`.
   The 402 message states the current affordable number directly.
2. Edit `model.max_tokens` in `data/hermes/config.yaml` (and the prod config).
3. `docker compose restart hermes`.
4. Send a test chat; confirm a non-empty reply and no 402 in
   `data/hermes/auth.json`.

After switching the default model: native ceilings and per-token prices differ,
so re-check the cap against the new model's affordable budget. To remove the cap
entirely (use the native ceiling) delete the `max_tokens` line — only with enough
credits to cover the model's full output ceiling.

#### Managed Hermes context window (`context_length`)

Hermes Agent **hard-requires a ≥64K context window** for both the primary
`model` and the `auxiliary.compression` model, and refuses to start a turn
otherwise (`"context window of N tokens ... below the minimum 64,000 required by
Hermes Agent"`). For `qwen/qwen-2.5-72b-instruct` Hermes auto-detects only
**32,768**, so `model.context_length` and `auxiliary.compression.context_length`
**must be set explicitly** (currently `131072`). This is independent of the
`max_tokens` output cap and of OpenRouter credits.

`make hermes-sync-context` (and the optional
`HERMES_DEFAULT_MANAGED_CONTEXT_LENGTH` /
`HERMES_AUX_COMPRESSION_CONTEXT_LENGTH` env vars) is the mechanism to refresh
these overrides from provider metadata when the default model changes. After any
model swap, confirm both context_length values clear the 64K floor.

### Email magic-link (HER-33)

The signup verification, password-reset, MFA, and magic-link sign-in flows all share one `EmailOTPSender`. In production set:

- `EMAIL_KIND=resend`
- `EMAIL_RESEND_APIKEY=re_...` (Resend dashboard → API Keys)
- `EMAIL_FROM_ADDRESS="LuminaVault <auth@yourdomain.com>"` — sender domain MUST be verified in Resend
- `EMAIL_REPLY_TO=support@yourdomain.com` (optional)
- `TEAM_INVITE_BASE_URL=https://app.yourdomain.com` — public web origin used to build seven-day, single-use team invitation links

When `EMAIL_KIND` is unset or `logging`, the server writes OTPs to stderr instead of sending email. That is the dev/CI default; iOS clients hitting a production deploy with `EMAIL_KIND=logging` will appear to send OTPs successfully but no email ever arrives.
Team invitations use the same email transport. Production must set `TEAM_INVITE_BASE_URL` to the web app origin; local development defaults to `http://localhost:5173`.

### JWT key rotation (HER-33)

`JWT_HMAC_SECRETS` carries an ordered csv of `kid:secret,kid:secret` pairs. The first entry is the active signer; the rest stay loaded so in-flight tokens still verify during the rollover window. Each secret must be 32+ chars; duplicate kids are rejected at boot.

Zero-downtime rotation:

1. Generate a new 32-byte secret: `openssl rand -base64 48 | tr -d '/+=' | cut -c1-48`.
2. Prepend it to `JWT_HMAC_SECRETS`: `JWT_HMAC_SECRETS=newkid:NEW_SECRET,oldkid:OLD_SECRET`. Redeploy. New tokens sign under `newkid`; tokens still in flight under `oldkid` continue to verify.
3. Wait at least one access-token TTL (1 hour) plus your refresh-token TTL window (30 days) to let all sessions migrate to the new key.
4. Remove the old entry: `JWT_HMAC_SECRETS=newkid:NEW_SECRET`. Redeploy.

When `JWT_HMAC_SECRETS` is unset, the loader falls back to the legacy single-key envs (`JWT_HMAC_SECRET` + `JWT_KID`) — existing deploys keep working without a config change.

## Backdoors to keep out of production

- `PHONE_FIXED_OTP` and `MAGIC_FIXED_OTP` short-circuit the OTP flows for CI/dev. **Never** set them in production — anyone with the value can sign in as any user via those flows. They are intentionally absent from `docker-compose.production.yml`.

## Adding a new variable

1. Add `let foo = reader.string(forKey: "domain.foo", default: ...)` in code.
2. Add a line to `.env.example` under the matching `# --- domain ---` group with a safe default or `# REQUIRED` marker.
3. Add a line to `docker-compose.production.yml` `environment:` block: `DOMAIN_FOO: ${DOMAIN_FOO:-default}` (or `${DOMAIN_FOO:?required}` if production cannot run without it).
4. Add a matching line to `docker-compose.yml` if dev needs it.
5. Document the variable in this file if it has non-obvious semantics.

## Verifying drift

```sh
grep -hE '^[A-Z_]+=' .env.example | cut -d= -f1 | sort -u > /tmp/env-keys
grep -rhE 'forKey:\s*"([a-zA-Z.]+)"' Sources/App/ \
  | sed -E 's/.*"([a-zA-Z.]+)".*/\1/' \
  | awk '{
      out=""
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c == ".") { out=out"_" }
        else if (c ~ /[A-Z]/) { out=out"_"c }
        else { out=out toupper(c) }
      }
      print out
    }' | sort -u > /tmp/code-keys
diff /tmp/env-keys /tmp/code-keys
```

Any code-only key needs an `.env.example` entry. Any env-only key may be safe to delete.
