import Configuration
import FluentPostgresDriver
import Foundation
import HummingbirdFluent

/// Wraps a String into a `ConfigValue` for use in `InMemoryProvider` literals.
/// Variable references can't use the dictionary-literal type inference that
/// makes `"key": "value"` work, so test-config dictionaries needing dynamic
/// values pass them through `cfg(...)` for both clarity and type-correctness.
func cfg(_ value: String) -> ConfigValue {
    .init(.string(value), isSecret: false)
}

func cfg(_ value: Int) -> ConfigValue {
    .init(.int(value), isSecret: false)
}

/// Hummingbird's default response encoder emits dates as ISO-8601 strings
/// (see `RequestContext` extension in the framework). `JSONDecoder()`
/// defaults to `.deferredToDate` which expects a numeric. Every test that
/// decodes a response body containing a `Date` field needs the matching
/// `.iso8601` strategy — use `testJSONDecoder()` instead of `JSONDecoder()`.
func testJSONDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}

/// Centralized Postgres test config. Reads env so the same test suite runs
/// in two environments:
///
///   * Local dev:   `docker compose up -d postgres` exposes pg on
///                  127.0.0.1:5433 with password `luminavault`.
///   * GitHub CI:   the runner's `services.postgres` is reachable as
///                  `postgres:5432` with password `hermes_password`. CI sets
///                  POSTGRES_HOST/PORT/USER/PASSWORD/DATABASE to override.
///
/// All Postgres-backed tests should pull config from here instead of
/// hardcoding host/port/credentials.
enum TestPostgres {
    static var host: String {
        ProcessInfo.processInfo.environment["POSTGRES_HOST"] ?? "127.0.0.1"
    }

    static var port: Int {
        Int(ProcessInfo.processInfo.environment["POSTGRES_PORT"] ?? "") ?? 5433
    }

    static var username: String {
        ProcessInfo.processInfo.environment["POSTGRES_USER"] ?? "hermes"
    }

    static var password: String {
        ProcessInfo.processInfo.environment["POSTGRES_PASSWORD"] ?? "luminavault"
    }

    static var database: String {
        ProcessInfo.processInfo.environment["POSTGRES_DATABASE"] ?? "hermes_db"
    }

    static func configuration() -> SQLPostgresConfiguration {
        .init(
            hostname: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: .disable,
        )
    }
}
