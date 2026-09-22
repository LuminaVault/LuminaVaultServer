import FluentKit
import SQLKit

/// Phone writes (`reminder_create`, `calendar_create`) that could not reach
/// the device live. The app fetches them when it opens and posts each result
/// to the existing result endpoint, which marks the row delivered.
///
/// `id` is the command's own id, so a command that did reach the phone late
/// over the socket and a queued copy of it are the same row — the result for
/// either delivers both.
struct M134_CreateDeviceCommandQueue: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("device_command_queue")
            .field("id", .uuid, .identifier(auto: false))
            .field("tenant_id", .uuid, .required)
            .field("kind", .string, .required)
            .field("domain", .string)
            .field("payload", .string, .required)
            .field("created_at", .datetime)
            .field("expires_at", .datetime, .required)
            .field("delivered_at", .datetime)
            .field("result_ok", .bool)
            .field("result_error", .string)
            .create()
        try await (database as? any SQLDatabase)?.raw("""
        CREATE INDEX IF NOT EXISTS device_command_queue_pending_idx
        ON device_command_queue (tenant_id, created_at)
        WHERE delivered_at IS NULL
        """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("device_command_queue").delete()
    }
}
