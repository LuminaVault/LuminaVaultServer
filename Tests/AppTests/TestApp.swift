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
let dbTestReader = ConfigReader(providers: [
    InMemoryProvider(values: [
        "http.host": "127.0.0.1",
        "http.port": 0,
        "log.level": "warning",
        "postgres.host": cfg(TestPostgres.host),
        "postgres.port": cfg(TestPostgres.port),
        "postgres.database": cfg(TestPostgres.database),
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
    ]),
])
