import FluentKit
import SQLKit

/// HER-274 — opt-out flag for the chat auto-save-link post-processor.
/// Defaults to TRUE so existing users get the behavior on first push;
/// flip via `PUT /v1/me/privacy { autoSaveLinks: false }`.
struct M52_AddUserAutoSaveLinks: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .field("auto_save_links", .bool, .required, .sql(.default(true)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema)
            .deleteField("auto_save_links")
            .update()
    }
}
