import FluentKit

/// BYO-Hermes: optional user-chosen friendly name for the endpoint
/// (e.g. "My VPS"). Display-only; nullable so existing rows are untouched.
struct M82_AddUserHermesConfigName: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserHermesConfig.schema)
            .field("name", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserHermesConfig.schema)
            .deleteField("name")
            .update()
    }
}
