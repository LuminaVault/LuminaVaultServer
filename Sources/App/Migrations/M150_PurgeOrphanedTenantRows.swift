import FluentKit
import SQLKit

/// One-time cleanup of rows left behind by accounts deleted before
/// `TenantDataEraser` existed.
///
/// Account deletion relied on `ON DELETE CASCADE` from `users`, and these
/// tables have none, so every deleted account left its rows here. From now on
/// the deletion transaction erases them; this removes the backlog. A row is an
/// orphan when its tenant is neither a user nor a vault — `embedding_usage`
/// and the retrieval telemetry are keyed by vault, and a personal vault's id
/// is the user's id, so "neither" is exactly "the account is gone".
///
/// `billing_event_logs` is anonymized rather than deleted, for the
/// legal-retention reason given in `TenantDataEraser.erase`.
///
/// The table list is frozen here on purpose rather than read from
/// `TenantDataEraser`: a migration must do the same thing on every database
/// it ever runs on.
///
/// `revert` is a no-op. Deleted rows cannot be put back, and they belonged to
/// accounts that asked to be erased.
struct M150_PurgeOrphanedTenantRows: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        for table in [
            "agent_rooms",
            "device_command_queue",
            "idempotency_keys",
            "embedding_usage",
            "retrieval_telemetry_events",
            "retrieval_leak_reports",
        ] {
            try await sql.raw("""
            DELETE FROM \(ident: table) t
            WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.id = t.tenant_id)
              AND NOT EXISTS (SELECT 1 FROM vaults v WHERE v.id = t.tenant_id)
            """).run()
        }

        // The tenant lives inside the text key: `tenant:<id>` or
        // `freelane:tenant:<id>`. Compared as lower-case text so a malformed
        // key cannot fail a cast and abort the migration.
        try await sql.raw("""
        DELETE FROM workflow_spend_buckets b
        WHERE lower(b.scope_key) ~ '^(freelane:)?tenant:'
          AND NOT EXISTS (
              SELECT 1 FROM users u
              WHERE u.id::text = regexp_replace(lower(b.scope_key), '^(freelane:)?tenant:', '')
          )
          AND NOT EXISTS (
              SELECT 1 FROM vaults v
              WHERE v.id::text = regexp_replace(lower(b.scope_key), '^(freelane:)?tenant:', '')
          )
        """).run()

        try await sql.raw("""
        UPDATE billing_event_logs b SET user_id = NULL
        WHERE b.user_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = b.user_id)
        """).run()

        // Same leak as the live path: the FK nulled `actor_user_id` on team
        // vault activity but left the deleted person's display name. Every
        // writer (`VaultActivityRecorder`, `TeamController`) sets an actor, so
        // a NULL actor can only mean the actor's account was deleted.
        try await sql.raw("""
        UPDATE vault_activity_events SET actor_name = 'Deleted user'
        WHERE actor_user_id IS NULL AND actor_name <> 'Deleted user'
        """).run()
    }

    func revert(on _: any Database) async throws {}
}

private enum MigrationError: Error { case requiresSQL }
