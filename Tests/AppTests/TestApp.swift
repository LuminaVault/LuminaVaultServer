@testable import App
import Configuration
import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

/// Decodes `T` from a test response, and on failure says what actually came
/// back before rethrowing.
///
/// A failed request answers with an error envelope, not the success type, so
/// decoding it reports whichever key it misses first. `Key 'id' not found`
/// names the shape the test wanted and says nothing about the 4xx that caused
/// it — eight such failures across four unrelated suites turned out to be one
/// endpoint returning an error and four tests decoding it.
///
/// Rethrows the original `DecodingError`; this only adds the response.
func decodeReporting<T: Decodable>(
    _ type: T.Type,
    from response: TestResponse,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> T {
    do {
        return try testJSONDecoder().decode(type, from: Data(buffer: response.body))
    } catch {
        let body = String(buffer: response.body)
        Issue.record(
            "decoding \(T.self) failed — status \(response.status), body: \(body.prefix(400))",
            sourceLocation: sourceLocation
        )
        throw error
    }
}

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
        // Same reason as `dbTestConfigValuesBase`: the default
        // `hermes.dataRoot=/app/data/hermes` is a container path. Inside the
        // CI image it exists and these tests pass; on a macOS dev machine `/`
        // is read-only, so boot fails and even `GET /health` goes red. Pinning
        // both readers keeps local and CI runs agreeing.
        "hermes.dataRoot": "/tmp/luminavault-test-hermes",
        "vault.rootPath": "/tmp/luminavault-test",
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
    "mcp.publicBaseUrl": "https://api.example.com",
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

/// `dbTestReader` with the free lane switched off.
///
/// With the lane on, `LLMPreferencesController.effectiveWire` canonicalises
/// reads to managed for a user who cannot act on their choice — and a freshly
/// registered test user is free-tier with no credential. A suite asserting what
/// the controller *stored* has to turn the lane off; one asserting the lane
/// itself belongs in `FreeLaneGateTests`.
///
/// `cfg(Bool)`, not `cfg("false")`: `ConfigReader` reads the stored type rather
/// than coercing, so a string reads back as the default and switches nothing.
var dbTestReaderFreeLaneOff: ConfigReader {
    var values = dbTestConfigValuesBase
    values["postgres.database"] = cfg(TestDatabaseIsolation.resolvedDatabase)
    values["freelane.enabled"] = cfg(false)
    return ConfigReader(providers: [InMemoryProvider(values: values)])
}

private var dbTestConfigValues: [AbsoluteConfigKey: ConfigValue] {
    var values = dbTestConfigValuesBase
    values["postgres.database"] = cfg(TestDatabaseIsolation.resolvedDatabase)
    return values
}

/// DB-backed reader plus per-suite overrides.
///
/// Use this instead of hand-rolling a `ConfigReader` for a suite that needs a
/// couple of extra keys. A reader written from scratch silently omits every
/// default in `dbTestConfigValuesBase`, and the omissions do not look like
/// bugs — they look like keys the suite does not care about.
///
/// `lv.environment` is the one that bites. It defaults to `dev`, and roughly a
/// dozen `if fluentEnabled, lvEnvironment != "test"` guards in
/// `buildApplication` read it to decide whether to append long-running
/// background services: the cron and reminder schedulers, the ingestion
/// worker, mirror refresh, analytics maintenance. Those services never
/// terminate, so `app.test` never finishes tearing down and the test hangs
/// having already passed — which is exactly how four suites wedged the
/// integration job until it was killed by its timeout (#212).
func dbTestReader(overriding overrides: [AbsoluteConfigKey: ConfigValue]) -> ConfigReader {
    var values = dbTestConfigValues
    for (key, value) in overrides {
        values[key] = value
    }
    return ConfigReader(providers: [InMemoryProvider(values: values)])
}

/// DB-backed reader with the deterministic stub chat provider enabled.
/// `llm.provider=stub` swaps the real `HermesGatewayAdapter` for
/// `StubChatAdapter` under `.hermesGateway`, so a `managed`-mode chat
/// returns a canned reply with no upstream call. Scoped to tests that
/// assert an actual LLM reply; other DB tests keep the default gateway.
/// - Parameter freeLaneEnabled: leave `true` to exercise the free lane, or set
///   `false` when a test asserts on a user's *stored* LLM preference. With the
///   lane on, `LLMPreferencesController` canonicalises reads to managed for a
///   user who cannot actually use their choice — a fresh signup is free-tier
///   with no credential — so a BYOK round-trip reads back as managed even
///   though it persisted correctly. `FreeLaneGateTests` covers that policy.
func dbTestReaderWithStubChat(
    replyContent: String = "Hello from the LuminaVault default brain.",
    freeLaneEnabled: Bool = true
) -> ConfigReader {
    var values = dbTestConfigValues
    values["llm.provider"] = cfg("stub")
    values["llm.stub.replyContent"] = cfg(replyContent)
    values["freelane.enabled"] = cfg(freeLaneEnabled)
    return ConfigReader(providers: [InMemoryProvider(values: values)])
}
