@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit
import Testing

/// Validates the usage-summary data layer: month-to-date `usage_meter` token
/// sums and the `embedding_usage` lookup that `AnalyticsController` reads.
/// Exercises the same SQL the controller uses, against the real migrations.
@Suite(.serialized, .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct UsageSummaryAggregationTests {
    private static func withFluent<T: Sendable>(
        _ body: @Sendable (Fluent) async throws -> T
    ) async throws -> T {
        let fluent = try await makeFluent()
        do {
            let result = try await body(fluent)
            try await fluent.shutdown()
            return result
        } catch {
            try? await fluent.shutdown()
            throw error
        }
    }

    private static func makeFluent() async throws -> Fluent {
        let fluent = Fluent(logger: Logger(label: "test.usage"))
        fluent.databases.use(.postgres(configuration: TestPostgres.configuration()), as: .psql)
        await fluent.migrations.add(M00_EnableExtensions())
        await fluent.migrations.add(M01_CreateUser())
        await fluent.migrations.add(M31_CreateUsageMeter())
        await fluent.migrations.add(M35_AddUsageMeterCharsOut())
        await fluent.migrations.add(M56_CreateEmbeddingUsage())
        do {
            try await fluent.migrate()
            return fluent
        } catch {
            try? await fluent.shutdown()
            throw error
        }
    }

    private static func makeUser(_ slug: String, on db: any Database) async throws -> User {
        let user = User(email: "\(slug)@test.luminavault", username: slug, passwordHash: "stub-\(slug)")
        try await user.save(on: db)
        return user
    }

    @Test
    func `month-to-date llm + embedding tokens aggregate per tenant`() async throws {
        try await Self.withFluent { fluent in
            let slug = "usg\(UUID().uuidString.prefix(6).lowercased())"
            let user = try await Self.makeUser(slug, on: fluent.db())
            let tenantID = try user.requireID()
            let sql = try #require(fluent.db() as? any SQLDatabase)

            // Two usage rows this month for this tenant + one for another tenant.
            let other = try await Self.makeUser("oth\(UUID().uuidString.prefix(6).lowercased())", on: fluent.db())
            let otherID = try other.requireID()
            // Distinct models per row — the PK is (tenant_id, day, model).
            for (tid, model, tin, tout) in [(tenantID, "model-a", 100, 40), (tenantID, "model-b", 50, 10), (otherID, "model-a", 999, 999)] {
                try await sql.raw("""
                INSERT INTO usage_meter (tenant_id, day, model, mtok_in, mtok_out)
                VALUES (\(bind: tid), CURRENT_DATE, \(bind: model), \(bind: Int64(tin)), \(bind: Int64(tout)))
                """).run()
            }

            try await EmbeddingUsage(tenantID: tenantID, yearMonth: EmbeddingUsage.yearMonth(), tokensUsed: 777)
                .save(on: fluent.db())

            // Replicates AnalyticsController.llmTokens.
            var cal = Calendar(identifier: .gregorian); cal.timeZone = .gmt
            let periodStart = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
            struct Row: Decodable { let tin: Int; let tout: Int }
            let row = try await sql.raw("""
            SELECT COALESCE(SUM(mtok_in),0)::int AS tin, COALESCE(SUM(mtok_out),0)::int AS tout
            FROM usage_meter WHERE tenant_id = \(bind: tenantID) AND day >= \(bind: periodStart)
            """).first(decoding: Row.self)
            #expect(row?.tin == 150) // 100 + 50, other tenant excluded
            #expect(row?.tout == 50) // 40 + 10

            let embed = try await EmbeddingUsage.query(on: fluent.db())
                .filter(\.$tenantID == tenantID)
                .filter(\.$yearMonth == EmbeddingUsage.yearMonth())
                .first()
            #expect(Int(embed?.tokensUsed ?? 0) == 777)
        }
    }
}
