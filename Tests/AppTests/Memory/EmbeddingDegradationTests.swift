@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import Logging
import LuminaVaultShared
import SQLKit
import Testing

/// An embedding provider that is out of credit (OpenRouter's 402) or down
/// must not cost the user a capture. The memory is saved with
/// `embedding = NULL`, search falls back to words, and the heal pass in
/// `EmbeddingReembedService` fills the vector in once the provider answers.
///
/// The embedder is a stub (no keys, no network). The suite's database is a
/// clone that may hold other rows, so assertions look only at this suite's
/// own rows.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct EmbeddingDegradationTests {
    /// Fails like a provider in the chosen state; counts every call.
    actor SwitchableEmbedding: EmbeddingService {
        enum Mode {
            /// OpenRouter with an empty balance.
            case paymentRequired
            /// A 503 that survived the fallback chain.
            case outage
            case working
        }

        private(set) var mode: Mode
        private(set) var calls = 0

        init(_ mode: Mode) {
            self.mode = mode
        }

        func set(_ mode: Mode) {
            self.mode = mode
        }

        func embed(_ text: String, tenantID _: UUID) async throws -> [Float] {
            calls += 1
            switch mode {
            case .paymentRequired:
                throw EmbeddingProviderError.permanent(
                    reason: .paymentRequired,
                    response: .init(status: 402, message: "Insufficient credits")
                )
            case .outage:
                throw EmbeddingProviderError.transient(
                    reason: "stub http 503",
                    response: .init(status: 503, message: "upstream unavailable")
                )
            case .working:
                // A text marked REJECT is a bad input, not an outage.
                if text.contains("REJECT") {
                    throw EmbeddingProviderError.permanent(
                        reason: .requestRejected,
                        response: .init(status: 400, message: "input rejected")
                    )
                }
                return EmbeddingDegradationTests.realVector
            }
        }
    }

    static let realVector: [Float] = {
        var v = [Float](repeating: 0, count: 1536)
        v[1] = 1
        return v
    }()

    private static func sql(_ fluent: Fluent) throws -> any SQLDatabase {
        try #require(fluent.db() as? any SQLDatabase)
    }

    private static func user(_ fluent: Fluent) async throws -> UUID {
        let slug = "ed\(UUID().uuidString.prefix(8).lowercased())"
        let user = User(email: "\(slug)@test.luminavault", username: slug, passwordHash: "stub-\(slug)")
        try await user.save(on: fluent.db())
        try await DefaultAuthService.ensurePersonalVault(for: user, on: fluent.db())
        return try user.requireID()
    }

    private struct Missing: Decodable { let missing: Bool }

    /// True when the row has no embedding; nil when there is no such row.
    private static func embeddingMissing(_ fluent: Fluent, table: String = "memories", idColumn: String = "id", id: String) async throws -> Bool? {
        try await sql(fluent).raw("""
        SELECT embedding IS NULL AS missing FROM \(unsafeRaw: table) WHERE \(unsafeRaw: idColumn)::text = \(bind: id)
        """).first(decoding: Missing.self)?.missing
    }

    // MARK: - HTTP

    private static func register(client: some TestClientProtocol) async throws -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(
            string: #"{"email":"degrade-\#(suffix)@test.luminavault","username":"degrade\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
        )
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)).accessToken }
    }

    private static func upsert(client: some TestClientProtocol, token: String, content: String) async throws -> (HTTPResponse.Status, UUID?) {
        try await client.execute(
            uri: "/v1/memory/upsert",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(string: #"{"content":"\#(content)"}"#)
        ) { response in
            guard response.status == .ok else { return (response.status, nil) }
            let decoded = try testJSONDecoder().decode(MemoryUpsertResponse.self, from: Data(response.body.readableBytesView))
            return (response.status, decoded.memoryId)
        }
    }

    @Test
    func `upsert saves the memory without an embedding when the provider is out of credit`() async throws {
        let stub = SwitchableEmbedding(.paymentRequired)
        let app = try await buildApplication(reader: dbTestReader, embeddingServiceOverride: stub)
        let saved: UUID? = try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let (status, id) = try await Self.upsert(client: client, token: token, content: "Call the plumber on Thursday")
            #expect(status == .ok)
            return id
        }
        let id = try #require(saved)
        #expect(await stub.calls >= 1)
        try await withTestFluent(label: "test.degrade.upsert") { fluent in
            let missing = try await Self.embeddingMissing(fluent, id: id.uuidString.lowercased())
            #expect(missing == true)
        }
    }

    @Test
    func `editing a memory during an outage saves the new text without a stale vector`() async throws {
        let stub = SwitchableEmbedding(.working)
        let app = try await buildApplication(reader: dbTestReader, embeddingServiceOverride: stub)
        let saved: UUID = try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let (_, id) = try await Self.upsert(client: client, token: token, content: "Dentist at 9")
            let memoryID = try #require(id)

            await stub.set(.outage)
            let status = try await client.execute(
                uri: "/v1/memory/\(memoryID)",
                method: .patch,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"content":"Dentist moved to 10"}"#)
            ) { $0.status }
            #expect(status == .ok)
            return memoryID
        }
        let id = saved
        try await withTestFluent(label: "test.degrade.patch") { fluent in
            #expect(try await Self.embeddingMissing(fluent, id: id.uuidString.lowercased()) == true)
            struct Content: Decodable { let content: String }
            let row = try await Self.sql(fluent).raw("SELECT content FROM memories WHERE id = \(bind: id)").first(decoding: Content.self)
            #expect(row?.content == "Dentist moved to 10")
        }
    }

    // MARK: - Search

    @Test
    func `search without a query vector finds memories by their words, including unembedded ones`() async throws {
        try await withTestFluent(label: "test.degrade.search") { fluent in
            let tenant = try await Self.user(fluent)
            let memories = MemoryRepository(fluent: fluent)
            let unembedded = try await memories.create(
                tenantID: tenant, content: "Quarterly zebra migration report is due", embedding: nil
            ).requireID()
            let embedded = try await memories.create(
                tenantID: tenant, content: "Zebra crossings near the school", embedding: Self.realVector
            ).requireID()

            let search = HybridMemorySearch(
                memories: memories,
                chunks: MemoryChunkRepository(fluent: fluent),
                logger: Logger(label: "test.degrade.search")
            )
            let hits = try await search.search(tenantID: tenant, query: "zebra migration", queryEmbedding: nil, limit: 5)
            let hit = try #require(hits.first { $0.id == unembedded })
            #expect((hit.lexicalScore ?? 0) > 0)
            // Lexical hits survive the chat grounding floor.
            #expect(ChatGrounding.relevant([hit], maxDistance: 0.6).count == 1)

            // With a vector, the NULL row is excluded from the dense arm
            // instead of breaking the query.
            let dense = try await memories.semanticSearch(tenantID: tenant, queryEmbedding: Self.realVector, limit: 10)
            #expect(dense.contains { $0.id == embedded })
            #expect(!dense.contains { $0.id == unembedded })
        }
    }

    @Test
    func `chunk indexing during an outage stores chunks without vectors that the lexical arm still cites`() async throws {
        try await withTestFluent(label: "test.degrade.chunks") { fluent in
            let tenant = try await Self.user(fluent)
            let memories = MemoryRepository(fluent: fluent)
            let content = "# Trip\n\nThe ferry to Ilha Deserta leaves at noon.\n"
            let memoryID = try await memories.create(tenantID: tenant, content: content, embedding: nil).requireID()

            let chunks = MemoryChunkRepository(fluent: fluent)
            let indexer = DocumentChunkIndexer(
                chunks: chunks,
                embeddings: SwitchableEmbedding(.outage),
                logger: Logger(label: "test.degrade.chunks")
            )
            let count = try await indexer.index(
                tenantID: tenant, memoryID: memoryID, vaultFileID: nil, spaceID: nil,
                sourcePath: "trips/ferry.md", content: content
            )
            #expect(count > 0)

            struct ChunkRow: Decodable { let missing: Bool }
            let rows = try await Self.sql(fluent).raw("""
            SELECT embedding IS NULL AS missing FROM memory_chunks WHERE tenant_id = \(bind: tenant) AND memory_id = \(bind: memoryID)
            """).all(decoding: ChunkRow.self)
            let allMissing = rows.allSatisfy(\.missing)
            #expect(rows.count == count)
            #expect(allMissing)

            let hits = try await chunks.hybridSearch(tenantID: tenant, query: "ferry Ilha Deserta", queryEmbedding: nil, limit: 5)
            let hit = try #require(hits.first { $0.id == memoryID })
            #expect(hit.citation?.path == "trips/ferry.md")
        }
    }

    // MARK: - Heal pass

    private static func healer(
        _ fluent: Fluent,
        _ embeddings: any EmbeddingService,
        kind: EmbeddingProviderKind = .openRouter
    ) -> EmbeddingReembedService {
        EmbeddingReembedService(
            fluent: fluent,
            embeddings: embeddings,
            activeKind: kind,
            reembedEnabled: false,
            configuration: EmbeddingReembedService.Configuration(
                batchSize: 50,
                pause: .zero,
                healInterval: .seconds(600),
                healMaxBackoff: .seconds(1800)
            ),
            logger: Logger(label: "test.embedding.heal"),
            sleep: { _ in }
        )
    }

    private static func nullChunk(_ fluent: Fluent, tenantID: UUID, memoryID: UUID, text: String) async throws -> String {
        let chunkID = "heal-chunk-\(UUID().uuidString)"
        try await sql(fluent).raw("""
        INSERT INTO memory_chunks (chunk_id, document_id, tenant_id, memory_id, ordinal, start_line, end_line, text, content_sha256, embedding)
        VALUES (\(bind: chunkID), \(bind: "doc-\(memoryID)"), \(bind: tenantID), \(bind: memoryID), 0, 1, 1, \(bind: text), 'sha', NULL)
        """).run()
        return chunkID
    }

    @Test
    func `the heal pass probes a refusing provider once per window, then fills the NULLs once it recovers`() async throws {
        try await withTestFluent(label: "test.degrade.heal") { fluent in
            let tenant = try await Self.user(fluent)
            let memoryID = try await MemoryRepository(fluent: fluent).create(
                tenantID: tenant, content: "Saved while OpenRouter was out of credit \(UUID().uuidString)", embedding: nil
            ).requireID()
            let chunkID = try await Self.nullChunk(fluent, tenantID: tenant, memoryID: memoryID, text: "Chunk saved during the outage")

            let stub = SwitchableEmbedding(.paymentRequired)
            let healer = Self.healer(fluent, stub)

            // One call, then the pass stops: not one 402 per row.
            #expect(try await healer.healMissing() == .providerUnavailable(healed: 0))
            #expect(await stub.calls == 1)
            #expect(await healer.delayAfterHeal(.providerUnavailable(healed: 0)) == .seconds(600))
            #expect(try await healer.healMissing() == .providerUnavailable(healed: 0))
            #expect(await stub.calls == 2)
            #expect(await healer.delayAfterHeal(.providerUnavailable(healed: 0)) == .seconds(1200))
            #expect(await healer.delayAfterHeal(.providerUnavailable(healed: 0)) == .seconds(1800))
            #expect(try await Self.embeddingMissing(fluent, id: memoryID.uuidString.lowercased()) == true)

            // Provider back. The cursor moved past the probed rows, so it may
            // take the wrap-around pass to reach them; never more than two.
            await stub.set(.working)
            for _ in 0 ..< 3 {
                _ = try await healer.healMissing()
            }
            #expect(try await Self.embeddingMissing(fluent, id: memoryID.uuidString.lowercased()) == false)
            #expect(try await Self.embeddingMissing(fluent, table: "memory_chunks", idColumn: "chunk_id", id: chunkID) == false)
            // A caught-up pass resets the backoff.
            #expect(await healer.delayAfterHeal(.caughtUp(healed: 0, failed: 0)) == .seconds(600))
        }
    }

    @Test
    func `a row the provider rejects is skipped and the rest of the pass is healed`() async throws {
        try await withTestFluent(label: "test.degrade.heal.reject") { fluent in
            let tenant = try await Self.user(fluent)
            let memories = MemoryRepository(fluent: fluent)
            let bad = try await memories.create(tenantID: tenant, content: "REJECT this one \(UUID().uuidString)", embedding: nil).requireID()
            let good = try await memories.create(tenantID: tenant, content: "heal this one \(UUID().uuidString)", embedding: nil).requireID()

            let healer = Self.healer(fluent, SwitchableEmbedding(.working))
            for _ in 0 ..< 2 {
                let result = try await healer.healMissing()
                guard case .caughtUp = result else {
                    Issue.record("expected caughtUp, got \(result)")
                    return
                }
            }
            #expect(try await Self.embeddingMissing(fluent, id: good.uuidString.lowercased()) == false)
            #expect(try await Self.embeddingMissing(fluent, id: bad.uuidString.lowercased()) == true)
        }
    }

    @Test
    func `the heal pass refuses while the deterministic stub is the active provider`() async throws {
        try await withTestFluent(label: "test.degrade.heal.refuse") { fluent in
            let tenant = try await Self.user(fluent)
            let memoryID = try await MemoryRepository(fluent: fluent).create(
                tenantID: tenant, content: "stays unembedded \(UUID().uuidString)", embedding: nil
            ).requireID()
            let stub = SwitchableEmbedding(.working)
            #expect(try await Self.healer(fluent, stub, kind: .deterministic).healMissing() == .refused)
            #expect(await stub.calls == 0)
            #expect(try await Self.embeddingMissing(fluent, id: memoryID.uuidString.lowercased()) == true)
        }
    }
}
