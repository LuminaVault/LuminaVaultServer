@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

/// Postgres-backed tests for the weekly retrieval leak roll-up.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct RetrievalLeakReportWorkerTests {
    private static func makeTenant(on fluent: Fluent) async throws -> UUID {
        let id = UUID()
        let user = User(
            id: id,
            email: "leak-\(UUID().uuidString.prefix(8).lowercased())@test.luminavault",
            username: "leak-\(UUID().uuidString.prefix(6).lowercased())",
            passwordHash: "stub"
        )
        try await user.save(on: fluent.db())
        return id
    }

    private static func seed(
        _ tenantID: UUID, source: RetrievalSourcePath, distances: [Float], on fluent: Fluent
    ) async throws {
        try await RetrievalTelemetryEvent(.from(
            tenantID: tenantID, distances: distances, source: source, spaceID: nil, limit: 5
        )).create(on: fluent.db())
    }

    /// Window that brackets rows just inserted with `created_at = NOW()`.
    private static func nowWindow() -> RetrievalLeakReportWorker.Period {
        let now = Date()
        return .init(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600))
    }

    @Test
    func `report aggregates zero-hit rate and mean, once per window`() async throws {
        try await withTestFluent(label: "lv.test.leak.aggregate") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenantID = try await Self.makeTenant(on: fluent)

            // 4 retrievals: 1 zero-hit, 3 with hits (top distances .2/.4/.6).
            try await Self.seed(tenantID, source: .localReply, distances: [], on: fluent)
            try await Self.seed(tenantID, source: .localReply, distances: [0.2], on: fluent)
            try await Self.seed(tenantID, source: .query, distances: [0.4], on: fluent)
            try await Self.seed(tenantID, source: .query, distances: [0.6], on: fluent)

            let worker = RetrievalLeakReportWorker(fluent: fluent, logger: Logger(label: "test.leak"))
            let window = Self.nowWindow()

            #expect(try await worker.runLeakJob(tenantID: tenantID, window: window) == true)

            let reports = try await RetrievalLeakReport.query(on: fluent.db(), tenantID: tenantID).all()
            #expect(reports.count == 1)
            let r = try #require(reports.first)
            #expect(r.totalRetrievals == 4)
            #expect(r.zeroHitCount == 1)
            #expect(abs(r.zeroHitRate - 0.25) < 1e-9)
            #expect(abs((r.meanTopDistance ?? -1) - 0.4) < 1e-6) // mean of .2/.4/.6

            // Idempotent: a second run in the same window inserts nothing.
            #expect(try await worker.runLeakJob(tenantID: tenantID, window: window) == false)
            let after = try await RetrievalLeakReport.query(on: fluent.db(), tenantID: tenantID).count()
            #expect(after == 1)
        }
    }

    @Test
    func `tenant with no telemetry produces no report`() async throws {
        try await withTestFluent(label: "lv.test.leak.empty") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenantID = try await Self.makeTenant(on: fluent)

            let worker = RetrievalLeakReportWorker(fluent: fluent, logger: Logger(label: "test.leak"))
            #expect(try await worker.runLeakJob(tenantID: tenantID, window: Self.nowWindow()) == false)
            let count = try await RetrievalLeakReport.query(on: fluent.db(), tenantID: tenantID).count()
            #expect(count == 0)
        }
    }

    @Test
    func `tick only fires at Sunday 05 UTC`() async throws {
        try await withTestFluent(label: "lv.test.leak.gate") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let worker = RetrievalLeakReportWorker(fluent: fluent, logger: Logger(label: "test.leak"))
            // 1970-01-04 is the first Sunday; 05:00 UTC = 3d + 5h.
            let sunday5 = Date(timeIntervalSince1970: 3 * 86400 + 5 * 3600)
            let monday5 = Date(timeIntervalSince1970: 4 * 86400 + 5 * 3600)
            #expect(try await worker.tick(at: monday5) == 0) // wrong weekday, no-op
            #expect(RetrievalLeakReportWorker.hourComponent(of: sunday5) == 5)
            #expect(RetrievalLeakReportWorker.weekdayComponent(of: sunday5) == 1)
        }
    }
}
