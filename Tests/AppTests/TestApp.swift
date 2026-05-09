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
/// Credentials match docker-compose.yml (hermes user, hermes_db database).
let dbTestReader = ConfigReader(providers: [
    InMemoryProvider(values: [
        "http.host": "127.0.0.1",
        "http.port": "0",
        "log.level": "warning",
        "postgres.host": "127.0.0.1",
        "postgres.port": "5432",
        "postgres.database": "hermes_db",
        "postgres.user": "hermes",
        "postgres.password": "super_secret_local_password_change_me",
        "fluent.autoMigrate": "true",
        "jwt.hmac.secret": "test-secret-do-not-use-in-prod-32chars",
        "jwt.kid": "test-kid"
    ])
])
