import FluentKit

struct M11_CreateWebAuthnCredential: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(WebAuthnCredential.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("credential_id", .string, .required)
            .field("public_key", .data, .required)
            .field("sign_count", .int64, .required, .sql(.default(0)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "credential_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(WebAuthnCredential.schema).delete()
    }
}
