import Configuration
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import App

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
        "jwt.kid": "test-kid"
    ])
])

/// Config for tests that need the database. Requires `docker compose up -d postgres`.
/// Credentials match the current docker-compose.yml mapping (host 5433 →
/// container 5432, user hermes, password from POSTGRES_PASSWORD env).
/// Note: `postgres.port` and `http.port` are passed as integer literals;
/// `reader.int(forKey:)` does NOT parse string values, so quoting these
/// silently falls back to the default and lands you on the wrong server.
let dbTestReader = ConfigReader(providers: [
    InMemoryProvider(values: [
        "http.host": "127.0.0.1",
        "http.port": 0,
        "log.level": "warning",
        "postgres.host": "127.0.0.1",
        "postgres.port": 5433,
        "postgres.database": "hermes_db",
        "postgres.user": "hermes",
        "postgres.password": "luminavault",
        "fluent.autoMigrate": "true",
        "jwt.hmac.secret": "test-secret-do-not-use-in-prod-32chars",
        "jwt.kid": "test-kid",
        "hermes.gatewayKind": "logging",
        "vault.rootPath": "/tmp/luminavault-test"
    ])
])
