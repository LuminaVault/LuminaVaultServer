import Configuration
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging

/// HER-30 — one-shot CLI that runs Fluent migrations and exits. Mirrors the
/// migration registration used by `buildApplication` via the shared
/// `registerMigrations(on:)` helper so the two paths can never drift.
///
/// Invocation:
///   `swift run App migrate`              — apply pending migrations
///   `swift run App migrate --revert`     — revert the last batch
///   `./App migrate`
///
/// Reads the same `ConfigReader` chain as the server (CLI args, env, .env,
/// in-memory defaults) so `POSTGRES_*` carry over without a separate config
/// file. setup.sh calls this before booting the HTTP server so the schema
/// is at the expected revision regardless of `FLUENT_AUTOMIGRATE`.
func runMigrateCommand(reader: ConfigReader) async throws {
    var logger = Logger(label: "lv.cli.migrate")
    logger.logLevel = reader.string(forKey: "log.level", as: Logger.Level.self, default: .info)

    let revert = CommandLine.arguments.contains("--revert")

    let fluent = Fluent(logger: logger)
    fluent.databases.use(
        .postgres(configuration: .init(
            hostname: reader.string(forKey: "postgres.host", default: "127.0.0.1"),
            port: reader.int(forKey: "postgres.port", default: 5432),
            username: reader.string(forKey: "postgres.user", default: "luminavault"),
            password: reader.string(forKey: "postgres.password", default: "luminavault"),
            database: reader.string(forKey: "postgres.database", default: "luminavault"),
            tls: .disable,
        )),
        as: .psql,
    )
    await registerMigrations(on: fluent)

    if revert {
        logger.info("migrate --revert starting")
        try await fluent.revert()
        logger.info("migrate --revert done")
    } else {
        logger.info("migrate starting")
        try await fluent.migrate()
        logger.info("migrate done")
    }

    try await fluent.shutdown()
}
