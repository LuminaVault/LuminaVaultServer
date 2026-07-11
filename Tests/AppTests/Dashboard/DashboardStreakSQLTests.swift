@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import SQLKit
import Testing

@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct DashboardStreakSQLTests {
    private static func withTenant<T: Sendable>(
        _ body: @Sendable (Fluent, UUID) async throws -> T
    ) async throws -> T {
        try await withTestFluent(label: "test.dashboard-streak") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenantID = UUID()
            let user = User(
                id: tenantID,
                email: "dash-streak-\(tenantID.uuidString.prefix(8).lowercased())@test.luminavault",
                username: "dash-streak-\(tenantID.uuidString.prefix(8).lowercased())",
                passwordHash: "x"
            )
            try await user.save(on: fluent.db())
            return try await body(fluent, tenantID)
        }
    }

    private static func date(_ key: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        return try #require(formatter.date(from: key))
    }

    private static func insertMemory(
        fluent: Fluent,
        tenantID: UUID,
        day: String,
        content: String = "activity"
    ) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "need SQL")
        }
        try await sql.raw("""
        INSERT INTO memories (id, tenant_id, content, created_at)
        VALUES (\(bind: UUID()), \(bind: tenantID), \(bind: content), \(bind: try date(day)))
        """).run()
    }

    private static func insertConversation(
        fluent: Fluent,
        tenantID: UUID,
        day: String,
        title: String = "session"
    ) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "need SQL")
        }
        let createdAt = try date(day)
        try await sql.raw("""
        INSERT INTO conversations (id, tenant_id, title, created_at, updated_at)
        VALUES (\(bind: UUID()), \(bind: tenantID), \(bind: title), \(bind: createdAt), \(bind: createdAt))
        """).run()
    }

    @Test
    func `currentStreakDays counts distinct recent days and stops at gaps`() async throws {
        try await Self.withTenant { fluent, tenantID in
            try await Self.insertMemory(fluent: fluent, tenantID: tenantID, day: "2026-07-01")
            try await Self.insertMemory(fluent: fluent, tenantID: tenantID, day: "2026-07-01", content: "duplicate")
            try await Self.insertMemory(fluent: fluent, tenantID: tenantID, day: "2026-06-30")
            try await Self.insertMemory(fluent: fluent, tenantID: tenantID, day: "2026-06-29")
            try await Self.insertMemory(fluent: fluent, tenantID: tenantID, day: "2026-06-27")

            let streak = try await DashboardController.currentStreakDays(tenantID: tenantID, db: fluent.db())
            #expect(streak == 3)
        }
    }

    @Test
    func `currentStreakDays combines memory and conversation activity`() async throws {
        try await Self.withTenant { fluent, tenantID in
            try await Self.insertMemory(fluent: fluent, tenantID: tenantID, day: "2026-07-01")
            try await Self.insertConversation(fluent: fluent, tenantID: tenantID, day: "2026-06-30")
            try await Self.insertMemory(fluent: fluent, tenantID: tenantID, day: "2026-06-29")

            let streak = try await DashboardController.currentStreakDays(tenantID: tenantID, db: fluent.db())
            #expect(streak == 3)
        }
    }
}
