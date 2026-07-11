@testable import App
import Configuration
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

/// Minimal config for tests that don't touch the database.
/// `fluent.enabled=false` skips Fluent service registration entirely so tests
/// boot without any Postgres connection attempt.
let noDBTestReader = ConfigReader(providers: [
    InMemoryProvider(values: [
        "http.host": "127.0.0.1",
        "http.port": "0",
        "log.level": "warning",
        "fluent.enabled": "false",
        "jwt.hmac.secret": "test-secret-do-not-use-in-prod-32chars",
        "jwt.kid": "test-kid",
    ]),
])

/// Config for tests that need the database. Requires `docker compose up -d postgres`.
/// Credentials read via `TestPostgres` (env-overridable) so the same suite
/// runs locally and on CI without source edits.
/// Note: `postgres.port` and `http.port` are passed as integer literals;
/// `reader.int(forKey:)` does NOT parse string values, so quoting these
/// silently falls back to the default and lands you on the wrong server.
/// `cfg(...)` helper lives in `TestPostgres.swift` — it wraps non-literal
/// values into `ConfigValue` since Swift's `ExpressibleByLiteral` only fires
/// for literal expressions, not computed properties.
private let dbTestConfigValuesBase: [AbsoluteConfigKey: ConfigValue] = [
    "http.host": "127.0.0.1",
    "http.port": 0,
    "log.level": "warning",
    "postgres.host": cfg(TestPostgres.host),
    "postgres.port": cfg(TestPostgres.port),
    "postgres.user": cfg(TestPostgres.username),
    "postgres.password": cfg(TestPostgres.password),
    "fluent.autoMigrate": "true",
    "jwt.hmac.secret": "test-secret-do-not-use-in-prod-32chars",
    "jwt.kid": "test-kid",
    "hermes.gatewayKind": "logging",
    // Default `hermes.dataRoot=/app/data/hermes` does not exist on dev
    // machines (it's a container path), and SOULService.initIfMissing
    // 503s when it can't write SOUL.md. Pin to /tmp so any test that
    // walks the upsert-then-provision path (phone, magic-link, X OAuth)
    // is stable on macOS.
    "hermes.dataRoot": "/tmp/luminavault-test-hermes",
    "vault.rootPath": "/tmp/luminavault-test",
    // HER-137: pin the phone OTP generator to a fixed code so
    // `/v1/auth/phone/verify` tests are deterministic. Production must
    // never set this — non-empty value disables randomness.
    "phone.fixedOtp": "424242",
    // HER-138: same fixed-OTP pin for the email magic-link generator
    // so `/v1/auth/email/verify` tests can drive a known code. MUST
    // stay empty in prod for the same reason as `phone.fixedOtp`.
    "magic.fixedOtp": "313131",
    // HER-217: deterministic SecretBox master key for BYO Hermes
    // tests. 32 zero bytes base64-encoded. Never set this value in
    // prod — every tenant key derives from it via HKDF.
    "secret.masterKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    // HER-217: open private/loopback ranges so test-time SSRF
    // validation accepts 127.0.0.1 / docker-internal hosts. Prod
    // must leave this `false`.
    "byoHermes.allowPrivate": "true",
    // Audit S2 (2026-07-03) flipped requireHttps's default to true outside
    // `dev`, and `lv.environment` is "test" here. BYO tests PUT plain-http
    // loopback URLs, so waive it explicitly. Prod keeps the fail-closed default.
    "byoHermes.requireHttps": "false",
    // HER-254 fail-closed bearer guard fatals when lv.environment != "dev"
    // and hermes.apiKey is empty. Tests don't actually dial Hermes (the
    // gateway is `logging` mode above), so a dummy bearer is sufficient
    // to satisfy the guard.
    "hermes.apiKey": "test-hermes-bearer-do-not-use",
    "lv.environment": "test",
    // Audit S3 (2026-07-03) fail-closed guard: any non-dev environment must
    // set an explicit CORS allowlist or `buildApplication` fatals at boot.
    // Tests never exercise browser CORS; a loopback origin satisfies it.
    "cors.allowedOrigins": "http://127.0.0.1",
    // HER-310: skip bundled skill scan during tests — hundreds of legacy
    // SKILL.md files log parse warnings on every `buildApplication` boot.
    "skills.builtinScan.enabled": "false",
]

/// DB-backed reader; resolves `postgres.database` from the active suite's
/// isolated database when `IntegrationDatabaseTrait` has run.
var dbTestReader: ConfigReader {
    var values = dbTestConfigValuesBase
    values["postgres.database"] = cfg(TestDatabaseIsolation.resolvedDatabase)
    return ConfigReader(providers: [InMemoryProvider(values: values)])
}

private var dbTestConfigValues: [AbsoluteConfigKey: ConfigValue] {
    var values = dbTestConfigValuesBase
    values["postgres.database"] = cfg(TestDatabaseIsolation.resolvedDatabase)
    return values
}

/// DB-backed reader with the deterministic stub chat provider enabled.
/// `llm.provider=stub` swaps the real `HermesGatewayAdapter` for
/// `StubChatAdapter` under `.hermesGateway`, so a `managed`-mode chat
/// returns a canned reply with no upstream call. Scoped to tests that
/// assert an actual LLM reply; other DB tests keep the default gateway.
func dbTestReaderWithStubChat(
    replyContent: String = "Hello from the LuminaVault default brain."
) -> ConfigReader {
    var values = dbTestConfigValues
    values["llm.provider"] = cfg("stub")
    values["llm.stub.replyContent"] = cfg(replyContent)
    return ConfigReader(providers: [InMemoryProvider(values: values)])
}
