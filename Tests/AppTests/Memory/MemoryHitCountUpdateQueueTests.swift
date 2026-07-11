@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import SQLKit
import Testing

@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct MemoryHitCountUpdateQueueTests {
    private static func withTenant<T: Sendable>(
        _ body: @Sendable (Fluent, UUID) async throws -> T
    ) async throws -> T {
        try await withTestFluent(label: "test.memory-hit-queue") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenantID = UUID()
            let user = User(
                id: tenantID,
                email: "hitq-\(tenantID.uuidString.prefix(8).lowercased())@test.luminavault",
                username: "hitq-\(tenantID.uuidString.prefix(8).lowercased())",
                passwordHash: "x"
            )
            try await user.save(on: fluent.db())
            return try await body(fluent, tenantID)
        }
    }

    private static func hitCount(fluent: Fluent, id: UUID) async throws -> Int64 {
        let row = try #require(try await Memory.find(id, on: fluent.db()))
        return row.queryHitCount
    }

    @Test
    func `queue increments query hit count for enqueued memory ids`() async throws {
        try await Self.withTenant { fluent, tenantID in
            let repo = MemoryRepository(fluent: fluent)
            let memory = try await repo.create(
                tenantID: tenantID,
                content: "project alpha",
                embedding: DeterministicEmbeddingService().embed("project alpha")
            )
            let id = try memory.requireID()
            let queue = MemoryHitCountUpdateQueue(fluent: fluent)

            await queue.enqueue(ids: [id])
            await queue.drain()

            #expect(try await Self.hitCount(fluent: fluent, id: id) == 1)
        }
    }

    @Test
    func `semantic search enqueues returned hits without blocking on the update`() async throws {
        try await Self.withTenant { fluent, tenantID in
            let queue = MemoryHitCountUpdateQueue(fluent: fluent)
            let repo = MemoryRepository(fluent: fluent, hitCountUpdates: queue)
            let embedder = DeterministicEmbeddingService()
            let memory = try await repo.create(
                tenantID: tenantID,
                content: "alpha search target",
                embedding: embedder.embed("alpha search target")
            )
            let id = try memory.requireID()

            let hits = try await repo.semanticSearch(
                tenantID: tenantID,
                queryEmbedding: embedder.embed("alpha"),
                limit: 1
            )

            #expect(hits.map(\.id) == [id])
            await queue.drain()
            #expect(try await Self.hitCount(fluent: fluent, id: id) == 1)
        }
    }
}
