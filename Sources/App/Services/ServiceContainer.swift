import HummingbirdFluent
import JWTKit
import Logging

/// Typed bundle of long-lived services injected into routes/repositories.
/// Hummingbird's Application has no `app.storage` key system — pass this
/// struct explicitly into router builders and controllers.
struct ServiceContainer {
    let fluent: Fluent
    let jwtKeys: JWTKeyCollection
    let jwtKID: JWKIdentifier
    let logLevel: Logger.Level
    /// OAuth provider client IDs (audience claim). Empty string disables that provider.
    let appleClientID: String
    let googleClientID: String
    /// Filesystem root for `tenants/<id>/raw/` Hermes/vault directories.
    let vaultRootPath: String
    /// Selects which `HermesGateway` impl to use:
    ///   `filesystem` (default) — write profile.json into the shared volume.
    ///   `logging`              — dev stub; logs and returns hermes-<username>.
    ///   `http` / `docker_exec` — reserved for future impls; throw on use.
    let hermesGatewayKind: String
    /// Base URL of the Hermes OpenAI-compatible gateway. Inside the docker
    /// network the service hostname is `hermes` (compose service name).
    let hermesGatewayURL: String
    /// Filesystem root for Hermes profile data (the host `./data/hermes`
    /// mount; visible to Hummingbird as `/app/data/hermes`).
    let hermesDataRoot: String
    /// Default model name when chat requests don't specify one. Verify via
    /// `GET http://hermes:8642/v1/models` against the running container.
    let hermesDefaultModel: String
    /// HER-254: Bearer token shared with the central Hermes container's
    /// `API_SERVER_KEY` env var. Required (empty = container refuses to
    /// bind to 0.0.0.0). Outbound HTTP clients send it as
    /// `Authorization: Bearer <key>`. Empty in dev triggers a degraded
    /// boot per HER-242 contract — chat/memo/KB upstream calls will 401
    /// but signup still succeeds.
    let hermesAPIKey: String
    /// WebAuthn / passkeys.
    let webAuthnEnabled: Bool
    let webAuthnRelyingPartyID: String
    let webAuthnRelyingPartyName: String
    let webAuthnRelyingPartyOrigin: String
    /// APNS push delivery (per-user; tokens stored in `device_tokens` table).
    let apnsEnabled: Bool
    let apnsBundleID: String
    let apnsTeamID: String
    let apnsKeyID: String
    let apnsPrivateKeyPath: String
    let apnsEnvironment: String
    /// RevenueCat server-to-server webhook shared secret. The webhook
    /// controller compares this (constant-time) against the `Authorization`
    /// header on each inbound POST. Empty = webhook endpoint returns 503.
    let revenuecatWebhookSecret: String
    /// Daily Mtok cap for free/trial tier (in million tokens). Default 1.0.
    /// Pro/Ultimate tiers have no cap.
    let usageFreeMtokDaily: Double
    /// Daily Mtok cap per individual skill execution (in million tokens).
    /// Default 0.2. Prevents a single runaway skill from burning the
    /// entire daily budget.
    let usagePerSkillMtokDaily: Double
    /// Model slug to degrade to when a free user hits the 80% soft cap.
    /// Must match a model available on the Hermes gateway.
    let usageDegradeModel: String
    /// CORS allowed origins. Empty list = `*` (dev). Prod must set explicitly.
    let corsAllowedOrigins: [String]
    /// Admin shared-secret. Empty = admin endpoints return 404.
    let adminToken: String
    /// Billing gate. Defaults false so enforcement can ship dark.
    let billingEnforcementEnabled: Bool
    /// Local cold-storage root for lapsed vault archival.
    let billingColdStoragePath: String
    /// X (Twitter) OAuth 2.0 client ID — audit/audience reference; iOS does
    /// the actual token flow client-side and forwards the access_token.
    let xClientID: String
    /// HER-200 M3 — rate-limit storage selector: `memory` (default) | `redis`.
    /// `redis` reserves the env knob for a future Redis-backed PersistDriver;
    /// until that lands the factory falls back to memory with a warning.
    let rateLimitStorageKind: String
    /// SMS gateway selector: `logging` (default) | `twilio`.
    let smsKind: String
    /// Twilio account credentials. Required when `smsKind=twilio`.
    let twilioAccountSID: String
    let twilioAuthToken: String
    let twilioFromNumber: String
    /// HER-137: when non-empty, the phone OTP generator emits this code every
    /// time instead of a random one. Tests pin this to `424242` so they can
    /// drive `/v1/auth/phone/verify` deterministically. Leave empty in prod —
    /// a non-empty value is a security hole (predictable OTP).
    let phoneFixedOTP: String
    /// HER-138: same toggle for the email magic-link OTP generator. Tests
    /// pin `magic.fixedOtp` to drive `/v1/auth/email/verify` deterministically.
    /// MUST stay empty in prod.
    let magicLinkFixedOTP: String
    /// HER-199: Google Gemini API key. Empty = Gemini provider not registered.
    let geminiAPIKey: String
    /// HER-204: TTS provider selector. Defaults to `openai`. Only adapter
    /// wired today; other providers (elevenlabs/cartesia/google) land in
    /// follow-up tickets.
    let ttsProvider: String
    /// HER-204: Default model passed to the TTS adapter when the request
    /// body doesn't override. OpenAI default is `tts-1`.
    let ttsDefaultModel: String
    /// HER-204: Soft daily character budget (informational; not enforced
    /// in MVP). When char-aware budget gating ships, `UsageMeterService`
    /// reads this to deny at hard cap.
    let ttsCharactersDaily: Int64
    /// HER-33: Email transport selector. `logging` (default) writes OTPs
    /// to the log; `resend` posts to the Resend HTTP API. Production
    /// MUST set `resend` or the magic-link flow silently no-ops.
    let emailKind: String
    /// HER-33: Resend API key (required when `emailKind=resend`).
    let emailResendAPIKey: String
    /// HER-33: From address shown to recipients. Must be on a verified
    /// Resend sender domain (e.g. `LuminaVault <auth@lumina.app>`).
    let emailFromAddress: String
    /// HER-33: Optional Reply-To header. Empty omits the field.
    let emailReplyTo: String
    /// HER-240a: Image used for per-tenant Hermes containers spawned by
    /// `HermesContainerManager`. Distinct from the shared `hermesGatewayURL`
    /// instance (which still serves KB compile and other non-Grok routes).
    let hermesPerTenantImage: String
    /// HER-240a: Docker network name shared by all per-tenant Hermes
    /// containers + the server. Created on boot if absent.
    let hermesPerTenantNetwork: String
    /// HER-240a: Host directory under which each tenant's Hermes data volume
    /// is mounted (`{base}/{tenantID}` → `/opt/data` inside the container).
    let hermesPerTenantDataRootBase: String
    /// HER-240a: Inclusive lower / exclusive upper bound of the host port
    /// range used for per-tenant Hermes containers.
    let hermesPerTenantPortRangeStart: Int
    let hermesPerTenantPortRangeEnd: Int
    /// HER-240a: Idle TTL in seconds. Containers with no xai-oauth token
    /// whose `lastUsedAt` is older than this are stopped + removed by
    /// `HermesContainerManager.evictIdle()`. Containers with an active
    /// xai-oauth token are never evicted (their auth.json must persist).
    let hermesPerTenantIdleTTLSeconds: Int
    /// HER-240a: Path to the `docker` binary on the host that runs the
    /// server process. Defaults to `/usr/bin/docker`. Override on macOS
    /// dev (`/opt/homebrew/bin/docker`).
    let dockerBinaryPath: String
}
