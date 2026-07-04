import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// One-shot idempotent startup pass: ensures every existing tenant's SOUL.md
/// carries the canonical `SOULCore` covenant.
///
/// Write-path enforcement (`SOULService.write`) covers every future write,
/// but Hermes reads the profile mirror file directly on every chat turn —
/// a dormant user who never writes again would otherwise never receive the
/// covenant. Running through `SOULService.write` updates both the vault copy
/// and the Hermes mirror atomically.
///
/// Idempotent: `needsCoreMigration` short-circuits on files that already
/// contain the canonical block, so restarts are free and a future
/// `SOULCore.version` bump re-triggers the pass naturally.
struct SOULCoreMigrationJob {
    let fluent: Fluent
    let soulService: SOULService
    let logger: Logger

    func run() async throws {
        let users = try await User.query(on: fluent.db()).all()
        var migrated = 0
        var failed = 0
        for user in users {
            guard soulService.needsCoreMigration(for: user) else { continue }
            do {
                let body = try soulService.read(for: user)
                _ = try soulService.write(for: user, body: body)
                migrated += 1
            } catch {
                // Per-tenant failure (e.g. Hermes profile dir not writable)
                // must not block boot; write-path enforcement remains as the
                // steady-state guarantee for this tenant.
                failed += 1
                logger.warning(
                    "soul.core.migrate.failed",
                    metadata: [
                        "user": .string(user.username),
                        "error": .string("\(error)"),
                    ]
                )
            }
        }
        if migrated > 0 || failed > 0 {
            logger.info("soul.core.migrated count=\(migrated) failed=\(failed) scanned=\(users.count)")
        }
    }
}
