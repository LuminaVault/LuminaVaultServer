import FluentKit
import SQLKit

/// HER-252 — append-only telemetry log of `RoutedLLMTransport` failover
/// events. One row per recoverable provider failure that caused the
/// dispatcher to advance to the next candidate.
///
/// `tenant_id` is `ON DELETE SET NULL` (not CASCADE) so historical
/// incident data survives account deletion for fleet-wide analytics —
/// the row no longer identifies a user but the failure pattern stays.
///
/// Indexed on `(tenant_id, happened_at DESC)` for per-user history and
/// on `(provider, happened_at DESC)` for fleet-wide degradation views.
struct M48_CreateProviderFailoverEvents: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ProviderFailoverEvent.schema)
            .id()
            .field("tenant_id", .uuid,
                   .references(User.schema, "id", onDelete: .setNull))
            .field("provider", .string, .required)
            .field("model", .string)
            .field("status_code", .int)
            .field("error_code", .string)
            .field("fallback_provider", .string)
            .field("fallback_model", .string)
            .field("source", .string, .required)
            .field("happened_at", .datetime, .required)
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_provider_failover_tenant_happened
                ON \(raw: ProviderFailoverEvent.schema) (tenant_id, happened_at DESC)
            """).run()
            try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_provider_failover_provider_happened
                ON \(raw: ProviderFailoverEvent.schema) (provider, happened_at DESC)
            """).run()
        }
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_provider_failover_tenant_happened").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_provider_failover_provider_happened").run()
        }
        try await database.schema(ProviderFailoverEvent.schema).delete()
    }
}
