@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

/// Postgres-backed behaviour tests for the telemetry drain.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct RetrievalTelemetryWorkerTests {
    @Test
    func `enqueued samples are persisted`() async throws {
        try await withTestFluent(label: "lv.test.retrieval.telemetry") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenantID = UUID()

            let worker = RetrievalTelemetryWorker(fluent: fluent, logger: Logger(label: "test.telemetry"))
            worker.enqueue(.from(tenantID: tenantID, distances: [0.1, 0.2], source: .localReply, spaceID: nil, limit: 5))
            worker.enqueue(.from(tenantID: tenantID, distances: [], source: .query, spaceID: nil, limit: 5))
            worker.enqueue(.from(tenantID: tenantID, distances: [0.3], source: .agenticSearch, spaceID: nil, limit: 3))
            // Finishing the inbox lets the buffered items drain, then run() returns.
            worker.shutdownForTests()
            try await worker.run()

            let rows = try await RetrievalTelemetryEvent.query(on: fluent.db(), tenantID: tenantID).all()
            #expect(rows.count == 3)
            #expect(rows.filter(\.zeroHit).count == 1)
            let local = try #require(rows.first { $0.sourcePath == "local_reply" })
            #expect(local.hitCount == 2)
            #expect(abs((local.topDistance ?? -1) - 0.1) < 1e-6)
        }
    }

    @Test
    func `enqueue after shutdown is a no-op and never throws`() async throws {
        try await withTestFluent(label: "lv.test.retrieval.telemetry.shutdown") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenantID = UUID()

            let worker = RetrievalTelemetryWorker(fluent: fluent, logger: Logger(label: "test.telemetry"))
            worker.shutdownForTests()
            try await worker.run()
            // Post-shutdown enqueue is dropped, not fatal.
            worker.enqueue(.from(tenantID: tenantID, distances: [0.1], source: .localReply, spaceID: nil, limit: 5))

            let rows = try await RetrievalTelemetryEvent.query(on: fluent.db(), tenantID: tenantID).all()
            #expect(rows.isEmpty)
        }
    }
}
