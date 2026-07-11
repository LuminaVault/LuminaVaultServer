import Configuration
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging

/// HER-105 — one-shot CLI that reorganises existing captures on disk from the
/// legacy flat `raw/captures/<file>` layout into per-Space folders
/// `raw/<slug>/<file>` (unfiled rows → `raw/inbox/`), and rewrites
/// `vault_files.path` to match. Idempotent: rows already under their Space
/// folder are skipped; rows whose backing file is missing are left untouched
/// (the compile path tolerates orphans).
///
/// Invocation (inside the hummingbird container so it sees the same env):
///   `docker compose exec hummingbird swift run App backfill-vault-space-folders`
///
/// Reuses the server `ConfigReader` chain (CLI args, env, .env, defaults) so
/// `POSTGRES_*` and `VAULT_ROOT_PATH` carry over. Does not run migrations.
func runBackfillVaultSpaceFoldersCommand(reader: ConfigReader) async throws {
    var logger = Logger(label: "lv.cli.backfill-vault-space-folders")
    logger.logLevel = reader.string(forKey: "log.level", as: Logger.Level.self, default: .info)

    let fluent = Fluent(logger: logger)
    fluent.databases.use(
        .postgres(configuration: .init(
            hostname: reader.string(forKey: "postgres.host", default: "127.0.0.1"),
            port: reader.int(forKey: "postgres.port", default: 5432),
            username: reader.string(forKey: "postgres.user", default: "luminavault"),
            password: reader.string(forKey: "postgres.password", default: "luminavault"),
            database: reader.string(forKey: "postgres.database", default: "luminavault"),
            tls: .disable
        )),
        as: .psql
    )

    let vaultPaths = VaultPathService(
        rootPath: reader.string(forKey: "vault.rootPath", default: "/tmp/luminavault")
    )

    var moved = 0
    var skippedAlready = 0
    var skippedMissing = 0
    var failures = 0

    do {
        let db = fluent.db()
        // slug lookup for every space across all tenants
        let spaces = try await Space.query(on: db).all()
        var slugByID: [UUID: String] = [:]
        for space in spaces where space.id != nil {
            slugByID[space.id!] = space.slug
        }

        let fm = FileManager.default
        let files = try await VaultFile.query(on: db).all()
        for row in files {
            let tenantID = row.tenantID
            let folder = row.spaceID.flatMap { slugByID[$0] } ?? "inbox"
            let basename = (row.path as NSString).lastPathComponent
            let newRel = "\(folder)/\(basename)"
            if row.path == newRel {
                skippedAlready += 1
                continue
            }

            let rawRoot = vaultPaths.rawDirectory(for: tenantID)
            let source = rawRoot.appendingPathComponent(row.path)
            let dest = rawRoot.appendingPathComponent(newRel)
            guard fm.fileExists(atPath: source.path) else {
                logger.warning("skip missing file tenant=\(tenantID) path=\(row.path)")
                skippedMissing += 1
                continue
            }
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.moveItem(at: source, to: dest)
                row.path = newRel
                try await row.save(on: db)
                moved += 1
            } catch {
                logger.error("move failed tenant=\(tenantID) \(row.path) -> \(newRel): \(error)")
                failures += 1
            }
        }
    } catch {
        try? await fluent.shutdown()
        throw error
    }

    logger.info("backfill-vault-space-folders done moved=\(moved) already=\(skippedAlready) missing=\(skippedMissing) failures=\(failures)")
    try await fluent.shutdown()
}
