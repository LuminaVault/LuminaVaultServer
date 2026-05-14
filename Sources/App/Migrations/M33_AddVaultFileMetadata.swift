import FluentKit
import SQLKit

struct M33_AddVaultFileMetadata: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(VaultFile.schema)
            .field("metadata", .json)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(VaultFile.schema)
            .deleteField("metadata")
            .update()
    }
}
