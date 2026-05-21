import FluentKit

/// HER-252 — per-user credentials for external LLM providers (xAI direct,
/// Anthropic, OpenAI, OpenRouter, Ollama). Plaintext (API key, OAuth
/// refresh) is sealed via `SecretBox` (AES-GCM, per-tenant HKDF key) into
/// `ciphertext` + `nonce`. Providers like Ollama only need `base_url`
/// and leave the sealed pair null.
///
/// `verified_at` is stamped by `POST /v1/me/providers/{provider}/test`
/// on a successful 2xx probe. `last_failure_at` + `last_failure_code`
/// capture the most recent /test or runtime failover failure.
///
/// FK `ON DELETE CASCADE` to `users.id` (HER-92). Composite uniqueness
/// on `(tenant_id, provider)` enforces one row per user-per-provider.
struct M46_CreateUserProviderCredentials: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserProviderCredential.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("provider", .string, .required)
            .field("credential_kind", .string, .required)
            .field("ciphertext", .data)
            .field("nonce", .data)
            .field("base_url", .string)
            .field("label", .string)
            .field("verified_at", .datetime)
            .field("last_failure_at", .datetime)
            .field("last_failure_code", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "tenant_id", "provider")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserProviderCredential.schema).delete()
    }
}
