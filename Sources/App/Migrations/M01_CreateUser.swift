import FluentKit
import SQLKit

struct M01_CreateUser: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .id()
            .field("email", .string, .required)
            .field("password_hash", .string, .required)
            .field("is_verified", .bool, .required, .sql(.default(false)))
            .field("failed_login_attempts", .int, .required, .sql(.default(0)))
            .field("lockout_until", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "email")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema).delete()
    }
}
