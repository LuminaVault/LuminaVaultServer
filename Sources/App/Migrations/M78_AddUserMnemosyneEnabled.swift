import FluentKit
import SQLKit

/// Mnemosyne default-memory toggle for a tenant's managed Hermes.
/// Defaults to TRUE so existing managed tenants get Mnemosyne as the default
/// memory layer on their container's next restart; flip via
/// `PUT /v1/me/privacy { mnemosyneEnabled: false }` to fall back to Hermes'
/// native file memory.
struct M78_AddUserMnemosyneEnabled: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .field("mnemosyne_enabled", .bool, .required, .sql(.default(true)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema)
            .deleteField("mnemosyne_enabled")
            .update()
    }
}
