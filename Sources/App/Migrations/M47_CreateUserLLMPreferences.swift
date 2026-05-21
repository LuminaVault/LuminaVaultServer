import FluentKit

/// HER-252 — per-user LLM routing preference: primary `(provider,
/// model)` + ordered fallback chain. Consulted by
/// `UserPreferenceModelRouter` on every chat / query / kb-compile call.
///
/// 1:1 with `users` via `tenant_id UNIQUE`. Row absent ⇒ fall through to
/// the static `TableModelRouter` table. `fallback_chain` is JSON so we
/// store an ordered array of `{provider, model}` without a side table.
///
/// FK `ON DELETE CASCADE` to `users.id` (HER-92 account deletion).
struct M47_CreateUserLLMPreferences: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserLLMPreference.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("primary_provider", .string, .required)
            .field("primary_model", .string, .required)
            .field("fallback_chain", .json, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "tenant_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserLLMPreference.schema).delete()
    }
}
