import FluentKit
import SQLKit

/// HER-273 — multi-persona Hermes profiles per user. See
/// `UserHermesProfile` for the layering rationale on top of the
/// existing 1:1 `HermesProfile` container slot.
///
/// `skills_enabled` is a JSONB array of skill slugs (e.g.
/// `["kb-compile", "kb-ask"]`) — driven by the controller's PATCH
/// path. `is_default` is enforced as exactly-one-per-tenant by the
/// partial unique index below; the controller cannot create or
/// clear default flags out-of-band.
struct M51_CreateUserHermesProfiles: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserHermesProfile.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("slug", .string, .required)
            .field("label", .string, .required)
            .field("system_prompt", .string, .required)
            .field("is_default", .bool, .required, .sql(.default(false)))
            .field("skills_enabled", .array(of: .string), .required, .sql(.default(SQLLiteral.string("{}"))))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "tenant_id", "slug")
            .create()

        // Exactly one default per tenant. Use a partial unique index so
        // multiple non-default rows can coexist freely.
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE UNIQUE INDEX IF NOT EXISTS user_hermes_profiles_one_default_per_tenant
        ON user_hermes_profiles (tenant_id)
        WHERE is_default = TRUE
        """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try? await sql.raw("DROP INDEX IF EXISTS user_hermes_profiles_one_default_per_tenant").run()
        }
        try await database.schema(UserHermesProfile.schema).delete()
    }
}
