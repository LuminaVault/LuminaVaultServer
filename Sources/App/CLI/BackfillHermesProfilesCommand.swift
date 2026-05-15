import Configuration
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging

/// HER-29 — one-shot CLI that walks every `users` row and ensures a ready
/// `hermes_profiles` row exists for it. Idempotent. Safe to run repeatedly
/// (e.g. cron, post-deploy hook, manual ops). Reuses
/// `HermesProfileReconciler.reconcile()` so there is no parallel logic to
/// drift out of sync with the daily scheduled service.
///
/// Invocation:
///   `swift run App backfill-hermes-profiles`
///   `./App backfill-hermes-profiles`
///
/// Reads the same `ConfigReader` chain as the server (CLI args, env, .env,
/// in-memory defaults) so `POSTGRES_*` / `HERMES_DATA_ROOT` / etc. carry
/// over without a separate config file. Does not run migrations — the
/// schema is expected to be at the same revision as the running server.
func runBackfillHermesProfilesCommand(reader: ConfigReader) async throws {
    var logger = Logger(label: "lv.cli.backfill-hermes-profiles")
    logger.logLevel = reader.string(forKey: "log.level", as: Logger.Level.self, default: .info)

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

    defer {
        Task { try? await fluent.shutdown() }
    }

    let vaultPaths = VaultPathService(
        rootPath: reader.string(forKey: "vault.rootPath", default: "/tmp/luminavault"),
    )
    let hermesDataRoot = reader.string(forKey: "hermes.dataRoot", default: "/app/data/hermes")
    let gateway = makeHermesGateway(
        kind: reader.string(forKey: "hermes.gatewayKind", default: "filesystem"),
        dataRoot: hermesDataRoot,
        logger: logger,
    )
    let service = HermesProfileService(
        fluent: fluent,
        gateway: gateway,
        vaultPaths: vaultPaths,
    )
    let reconciler = HermesProfileReconciler(
        fluent: fluent,
        service: service,
        vaultPaths: vaultPaths,
        hermesDataRoot: hermesDataRoot,
        logger: logger,
    )

    logger.info("backfill-hermes-profiles starting")
    let summary = try await reconciler.reconcile()
    logger.info(
        "backfill-hermes-profiles done scanned=\(summary.usersScanned) created=\(summary.profilesCreated) recovered=\(summary.profilesRecovered) ok=\(summary.profilesAlreadyOK) failures=\(summary.failures.count)",
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(summary)
    if let json = String(data: data, encoding: .utf8) {
        print(json)
    }

    try await fluent.shutdown()
}
