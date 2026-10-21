@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import SQLKit
import Testing

/// `EmbeddingReembedService` rewrites every stored text vector through the
/// active provider: embedding column only, cursor persisted per batch so a
/// restart resumes, `completed_at` once a target is done, nothing at all
/// under the deterministic stub, and a failing row is skipped rather than
/// blocking the run.
///
/// The embedder is a stub (no keys, no network). The suite's database is a
/// clone that may hold other rows, so assertions look only at this suite's
/// own rows; each test starts from an empty progress table.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct EmbeddingReembedServiceTests {
    /// Every text becomes the unit vector on axis 1; a text containing
    /// `FAIL` (or every text, when `failAll`) throws. Counts calls per text.
    private actor StubEmbedding: EmbeddingService {
        private(set) var calls: [String: Int] = [:]
        private var failAll = false

        func setFailAll(_ value: Bool) {
            failAll = value
        }

        func embed(_ text: String, tenantID _: UUID) async throws -> [Float] {
            calls[text, default: 0] += 1
            if failAll || text.contains("FAIL") {
                throw EmbeddingProviderError.transient(reason: "stub down")
            }
            return EmbeddingReembedServiceTests.realVector
        }
    }

    static let realVector: [Float] = {
        var v = [Float](repeating: 0, count: 1536)
        v[1] = 1
        return v
    }()

    /// What the deterministic stub would have stored: axis 0.
    static let fakeVector: [Float] = {
        var v = [Float](repeating: 0, count: 1536)
        v[0] = 1
        return v
    }()

    private static let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

    private static func service(
        _ fluent: Fluent,
        _ embeddings: StubEmbedding,
        kind: EmbeddingProviderKind = .openRouter,
        batchSize: Int = 50
    ) -> EmbeddingReembedService {
        EmbeddingReembedService(
            fluent: fluent,
            embeddings: embeddings,
            activeKind: kind,
            configuration: EmbeddingReembedService.Configuration(batchSize: batchSize, pause: .zero),
            logger: Logger(label: "test.embedding.reembed"),
            sleep: noSleep
        )
    }

    private static func sql(_ fluent: Fluent) throws -> any SQLDatabase {
        try #require(fluent.db() as? any SQLDatabase)
    }

    /// The progress table is per suite clone; start each test from scratch.
    private static func resetProgress(_ fluent: Fluent) async throws {
        try #require(TestDatabaseIsolation.resolvedDatabase != TestDatabaseIsolation.baseDatabase)
        try await sql(fluent).raw("DELETE FROM embedding_reembed_progress").run()
    }

    private static func user(_ fluent: Fluent) async throws -> UUID {
        let slug = "re\(UUID().uuidString.prefix(8).lowercased())"
        let user = User(email: "\(slug)@test.luminavault", username: slug, passwordHash: "stub-\(slug)")
        try await user.save(on: fluent.db())
        try await DefaultAuthService.ensurePersonalVault(for: user, on: fluent.db())
        return try user.requireID()
    }

    private static func memory(_ fluent: Fluent, tenantID: UUID, content: String) async throws -> UUID {
        try await MemoryRepository(fluent: fluent).create(
            tenantID: tenantID,
            content: content,
            embedding: fakeVector
        ).requireID()
    }

    private static func chunk(_ fluent: Fluent, tenantID: UUID, memoryID: UUID, text: String) async throws -> String {
        let chunkID = "test-chunk-\(UUID().uuidString)"
        try await sql(fluent).raw("""
        INSERT INTO memory_chunks (chunk_id, document_id, tenant_id, memory_id, ordinal, start_line, end_line, text, content_sha256, embedding)
        VALUES (\(bind: chunkID), \(bind: "doc-\(memoryID)"), \(bind: tenantID), \(bind: memoryID), 0, 1, 1,
                \(bind: text), 'sha', \(unsafeRaw: "'\(MemoryRepository.formatVector(fakeVector))'::vector"))
        """).run()
        return chunkID
    }

    private static func archived(_ fluent: Fluent, tenantID: UUID, content: String) async throws -> UUID {
        let id = UUID()
        try await sql(fluent).raw("""
        INSERT INTO memories_archive (id, tenant_id, content, embedding, created_at)
        VALUES (\(bind: id), \(bind: tenantID), \(bind: content), \(unsafeRaw: "'\(MemoryRepository.formatVector(fakeVector))'::vector"), now())
        """).run()
        return id
    }

    private struct VectorRow: Decodable { let embedding: String }

    /// Axis the stored unit vector points along: 0 = still fake, 1 = rewritten.
    private static func axis(_ fluent: Fluent, table: String, idColumn: String = "id", id: String) async throws -> Int? {
        let row = try await sql(fluent).raw("""
        SELECT embedding::text AS embedding FROM \(unsafeRaw: table) WHERE \(unsafeRaw: idColumn)::text = \(bind: id)
        """).first(decoding: VectorRow.self)
        guard let text = row?.embedding else { return nil }
        let values = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").compactMap { Float($0) }
        return values.firstIndex(of: 1)
    }

    @Test
    func `rewrites memories, chunks and archive, then marks every target complete`() async throws {
        try await withTestFluent(label: "test.reembed.all") { fluent in
            try await Self.resetProgress(fluent)
            let tenant = try await Self.user(fluent)
            let memoryID = try await Self.memory(fluent, tenantID: tenant, content: "Flight to Lisbon on Friday")
            let chunkID = try await Self.chunk(fluent, tenantID: tenant, memoryID: memoryID, text: "Flight to Lisbon")
            let archiveID = try await Self.archived(fluent, tenantID: tenant, content: "Old note about Porto")
            try await Self.sql(fluent).raw("""
            UPDATE memories SET graph_x = 1, graph_y = 2, graph_z = 3, graph_layout_at = now() WHERE id = \(bind: memoryID)
            """).run()
            struct Before: Decodable { let created_at: Date?; let review_state: String }
            let before = try #require(try await Self.sql(fluent).raw("SELECT created_at, review_state FROM memories WHERE id = \(bind: memoryID)").first(decoding: Before.self))

            let stub = StubEmbedding()
            let ran = try await Self.service(fluent, stub).runToCompletion()
            #expect(ran)

            #expect(try await Self.axis(fluent, table: "memories", id: memoryID.uuidString.lowercased()) == 1)
            #expect(try await Self.axis(fluent, table: "memory_chunks", idColumn: "chunk_id", id: chunkID) == 1)
            #expect(try await Self.axis(fluent, table: "memories_archive", id: archiveID.uuidString.lowercased()) == 1)

            // Embedding column only.
            let after = try #require(try await Self.sql(fluent).raw("SELECT created_at, review_state FROM memories WHERE id = \(bind: memoryID)").first(decoding: Before.self))
            #expect(after.created_at == before.created_at)
            #expect(after.review_state == before.review_state)

            // The layout projected from the fake vectors is cleared for the worker.
            struct Layout: Decodable { let graph_x: Double? }
            let layout = try await Self.sql(fluent).raw("SELECT graph_x FROM memories WHERE id = \(bind: memoryID)").first(decoding: Layout.self)
            #expect(layout?.graph_x == nil)

            let service = Self.service(fluent, stub)
            for target in EmbeddingReembedService.Target.all {
                let progress = try #require(try await service.progress(for: target))
                #expect(progress.completedAt != nil, "\(target.name)")
                #expect(progress.rowsDone >= 1, "\(target.name)")
            }
        }
    }

    @Test
    func `persists the cursor per batch and a restart resumes instead of starting over`() async throws {
        try await withTestFluent(label: "test.reembed.resume") { fluent in
            try await Self.resetProgress(fluent)
            let tenant = try await Self.user(fluent)
            var contents: [String] = []
            for index in 0 ..< 5 {
                let content = "resume note \(index) \(UUID().uuidString)"
                contents.append(content)
                _ = try await Self.memory(fluent, tenantID: tenant, content: content)
            }

            let stub = StubEmbedding()
            let first = Self.service(fluent, stub, batchSize: 2)
            let result = try await first.runBatch(.memories)
            guard case let .progressed(reembedded, _, _) = result else {
                Issue.record("expected progress, got \(result)")
                return
            }
            let afterOne = try #require(try await first.progress(for: .memories))
            #expect(afterOne.lastID != nil)
            #expect(afterOne.rowsDone == Int64(reembedded))
            #expect(afterOne.completedAt == nil)

            // "Restart": a fresh instance reads the cursor back.
            let second = Self.service(fluent, stub, batchSize: 2)
            try await second.runToCompletion()

            let calls = await stub.calls
            for content in contents {
                #expect(calls[content] == 1, "re-embedded more than once or never: \(content)")
            }
            let done = try #require(try await second.progress(for: .memories))
            #expect(done.completedAt != nil)
            #expect(done.rowsDone >= Int64(contents.count))
        }
    }

    @Test
    func `a completed target is never walked again`() async throws {
        try await withTestFluent(label: "test.reembed.complete") { fluent in
            try await Self.resetProgress(fluent)
            let tenant = try await Self.user(fluent)
            let content = "complete once \(UUID().uuidString)"
            _ = try await Self.memory(fluent, tenantID: tenant, content: content)

            let stub = StubEmbedding()
            try await Self.service(fluent, stub).runToCompletion()
            let again = try await Self.service(fluent, stub).runBatch(.memories)
            #expect(again == .alreadyComplete)
            try await Self.service(fluent, stub).runToCompletion()
            #expect(await stub.calls[content] == 1)
        }
    }

    @Test
    func `refuses to run while the deterministic stub is the active provider`() async throws {
        try await withTestFluent(label: "test.reembed.refuse") { fluent in
            try await Self.resetProgress(fluent)
            let tenant = try await Self.user(fluent)
            let memoryID = try await Self.memory(fluent, tenantID: tenant, content: "should stay fake")

            let stub = StubEmbedding()
            let service = Self.service(fluent, stub, kind: .deterministic)
            let ran = try await service.runToCompletion()
            #expect(!ran)
            #expect(await stub.calls.isEmpty)
            #expect(try await Self.axis(fluent, table: "memories", id: memoryID.uuidString.lowercased()) == 0)
            #expect(try await service.progress(for: .memories) == nil)
        }
    }

    @Test
    func `a failing row is skipped and counted; the rest of the batch is rewritten`() async throws {
        try await withTestFluent(label: "test.reembed.failrow") { fluent in
            try await Self.resetProgress(fluent)
            let tenant = try await Self.user(fluent)
            let good = try await Self.memory(fluent, tenantID: tenant, content: "good note \(UUID().uuidString)")
            let bad = try await Self.memory(fluent, tenantID: tenant, content: "FAIL note \(UUID().uuidString)")

            let stub = StubEmbedding()
            let service = Self.service(fluent, stub)
            try await service.runToCompletion()

            #expect(try await Self.axis(fluent, table: "memories", id: good.uuidString.lowercased()) == 1)
            #expect(try await Self.axis(fluent, table: "memories", id: bad.uuidString.lowercased()) == 0)
            let progress = try #require(try await service.progress(for: .memories))
            #expect(progress.completedAt != nil)
            #expect(progress.rowsFailed >= 1)
        }
    }

    @Test
    func `a batch where the provider fails every row leaves the cursor in place and backs off`() async throws {
        try await withTestFluent(label: "test.reembed.down") { fluent in
            try await Self.resetProgress(fluent)
            let tenant = try await Self.user(fluent)
            _ = try await Self.memory(fluent, tenantID: tenant, content: "provider down \(UUID().uuidString)")

            let stub = StubEmbedding()
            await stub.setFailAll(true)
            let service = EmbeddingReembedService(
                fluent: fluent,
                embeddings: stub,
                activeKind: .openRouter,
                configuration: EmbeddingReembedService.Configuration(
                    batchSize: 50,
                    pause: .seconds(2),
                    failedBatchesBeforeBackoff: 2,
                    backoffBase: .seconds(30),
                    maxBackoff: .seconds(60)
                ),
                logger: Logger(label: "test.embedding.reembed"),
                sleep: Self.noSleep
            )

            for _ in 0 ..< 3 {
                let result = try await service.runBatch(.memories)
                guard case .providerFailed = result else {
                    Issue.record("expected providerFailed, got \(result)")
                    return
                }
            }
            // Three failed batches, threshold two: 30s · 2^1, capped at 60s.
            #expect(await service.delayAfterFailedBatch() == .seconds(60))
            let progress = try await service.progress(for: .memories)
            #expect(progress?.lastID == nil)
            #expect(progress?.completedAt == nil)

            // Provider back: the same rows are picked up, nothing was skipped.
            await stub.setFailAll(false)
            let recovered = try await service.runBatch(.memories)
            guard case let .progressed(reembedded, _, _) = recovered else {
                Issue.record("expected progress after recovery, got \(recovered)")
                return
            }
            #expect(reembedded >= 1)
        }
    }

    @Test
    func `a row edited after it was read keeps the vector its writer stored`() async throws {
        // The guard is the `text = <what was embedded>` predicate on the
        // UPDATE; simulate the edit by changing content between read and write
        // through an embedder that mutates the row while "embedding".
        actor EditingEmbedding: EmbeddingService {
            let fluent: Fluent
            let memoryID: UUID
            init(fluent: Fluent, memoryID: UUID) {
                self.fluent = fluent
                self.memoryID = memoryID
            }

            func embed(_: String, tenantID _: UUID) async throws -> [Float] {
                if let sql = fluent.db() as? any SQLDatabase {
                    try await sql.raw("UPDATE memories SET content = 'edited by the user' WHERE id = \(bind: memoryID)").run()
                }
                return EmbeddingReembedServiceTests.realVector
            }
        }

        try await withTestFluent(label: "test.reembed.race") { fluent in
            try await Self.resetProgress(fluent)
            let tenant = try await Self.user(fluent)
            let memoryID = try await Self.memory(fluent, tenantID: tenant, content: "original \(UUID().uuidString)")
            let service = EmbeddingReembedService(
                fluent: fluent,
                embeddings: EditingEmbedding(fluent: fluent, memoryID: memoryID),
                activeKind: .openRouter,
                targets: [.memories],
                configuration: EmbeddingReembedService.Configuration(pause: .zero),
                logger: Logger(label: "test.embedding.reembed"),
                sleep: Self.noSleep
            )
            try await service.runToCompletion()
            #expect(try await Self.axis(fluent, table: "memories", id: memoryID.uuidString.lowercased()) == 0)
        }
    }
}
