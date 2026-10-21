import Foundation
import SQLKit

/// Tenant rows that no `ON DELETE CASCADE` from `users` reaches.
///
/// Most per-tenant tables hang off `users(id)` with a cascade, so deleting the
/// user row erases them. These do not, and until this existed they outlived
/// account deletion indefinitely. They are erased explicitly rather than given
/// a foreign key because their `tenant_id` is not always a user id:
///
/// - `embedding_usage`, `retrieval_telemetry_events` and
///   `retrieval_leak_reports` are keyed by the *memory vault* — the user id for
///   a personal vault, a team vault's id otherwise — so a key to `users` would
///   reject every team-vault row.
/// - `workflow_spend_buckets` has no tenant column at all; the tenant is
///   embedded in the text `scope_key` (`tenant:<id>`, `freelane:tenant:<id>`).
/// - `agent_rooms` (members and messages cascade from the room),
///   `device_command_queue` and `idempotency_keys` are always the user, but a
///   key to `users` would also break every test that writes them for a bare
///   UUID; one erasure list for all of them is simpler to keep complete.
///
/// `AccountDeletionTests` ("every tenant table is erased or cascades") fails when a new
/// table with a `tenant_id`/`user_id` column is neither cascaded nor listed
/// here, so the list cannot silently fall behind the schema.
///
/// Callers run this in the same transaction as the `users` delete.
enum TenantDataEraser {
    /// Deleted outright, `WHERE tenant_id = <user id>`.
    static let erasedTables = [
        "agent_rooms",
        "device_command_queue",
        "idempotency_keys",
        "embedding_usage",
        "retrieval_telemetry_events",
        "retrieval_leak_reports",
    ]

    /// Kept, with the personal identifier removed. See `erase` for why.
    static let anonymizedTables = [
        "billing_event_logs",
        "vault_activity_events",
    ]

    /// Not erased and not anonymized here, because something else already
    /// handles them. Listed so the schema-completeness test can tell
    /// "considered" from "forgotten".
    static let handledElsewhere = [
        // `tenant_id` → users ON DELETE SET NULL. What remains is provider,
        // model and status code: no personal data.
        "provider_failover_events",
    ]

    static func erase(tenantID: UUID, on sql: any SQLDatabase) async throws {
        for table in erasedTables {
            // Identifiers come from the static list above, never from input.
            try await sql.raw("""
            DELETE FROM \(ident: table) WHERE tenant_id = \(bind: tenantID)
            """).run()
        }

        // Both spellings the spend gates write (`WorkflowSpendService`,
        // `FreeLaneGate`). Compared case-insensitively because the key is
        // built from `uuidString` (upper case) and a hand-written one may not be.
        try await sql.raw("""
        DELETE FROM workflow_spend_buckets
        WHERE lower(scope_key) IN (\(bind: "tenant:\(tenantID.uuidString.lowercased())"),
                                   \(bind: "freelane:tenant:\(tenantID.uuidString.lowercased())"))
        """).run()

        // Store / RevenueCat webhook log: kept. These rows record that a
        // payment event was received and processed, which is a financial
        // record the business must retain for tax and accounting (GDPR
        // Art. 17(3)(b) — erasure does not apply where retention is a legal
        // obligation). `event_id` (the store's id) also has to survive so a
        // webhook redelivered after deletion is still recognised as a
        // duplicate. The only personal field is `user_id`; dropping it leaves
        // the record with nothing that points back at the person.
        try await sql.raw("""
        UPDATE billing_event_logs SET user_id = NULL WHERE user_id = \(bind: tenantID)
        """).run()

        // A team vault's activity feed belongs to the team and stays, but the
        // FK only nulls `actor_user_id`; `actor_name` would keep showing the
        // deleted person's name. Personal-vault rows cascade away already.
        try await sql.raw("""
        UPDATE vault_activity_events SET actor_name = \(bind: deletedActorName)
        WHERE actor_user_id = \(bind: tenantID)
        """).run()
    }

    static let deletedActorName = "Deleted user"
}
