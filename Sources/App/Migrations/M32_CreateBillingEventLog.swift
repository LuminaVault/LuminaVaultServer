import FluentKit

struct M32_CreateBillingEventLog: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("billing_event_logs")
            .id()
            .field("event_id", .string, .required)
            .field("event_type", .string, .required)
            .field("user_id", .uuid)
            .field("processed_at", .datetime)
            .unique(on: "event_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("billing_event_logs").delete()
    }
}
