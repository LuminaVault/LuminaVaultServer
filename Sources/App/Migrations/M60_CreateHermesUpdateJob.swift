import FluentKit

/// HER-330 — table backing the owner-triggered "Update Hermes" jobs. See
/// `HermesUpdateJob`. Steps are stored as a JSON string column so the whole
/// snapshot is read/written atomically.
struct M60_CreateHermesUpdateJob: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(HermesUpdateJob.schema)
            .id()
            .field("state", .string, .required)
            .field("steps_json", .string, .required)
            .field("from_version", .string)
            .field("to_version", .string)
            .field("error_message", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(HermesUpdateJob.schema).delete()
    }
}
