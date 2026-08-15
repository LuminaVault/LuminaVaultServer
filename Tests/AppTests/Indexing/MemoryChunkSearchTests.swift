@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import Logging
import LuminaVaultShared
import Testing

/// DB-backed tests for the chunk index and hybrid retrieval.
///
/// The assertion that justifies the whole feature is
/// `a citation points at source lines that really contain the match`: it takes
/// the `path` / `startLine` / `endLine` a hit claims, re-reads exactly those
/// lines from the original document, and requires the searched term to be
/// there. If that ever fails, every citation the product renders is a lie.
///
/// Run with `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct MemoryChunkSearchTests {
    /// A document with distinct headings and a rare token per section, so a
    /// lexical hit can only come from one known line range.
    private static let document = """
    # Hermes routing

    The router picks a provider per request.

    ## Fallbacks

    When the primary provider errors we retry once, then fall through to the
    secondary. The escalation codeword is zarquonfallback.

    ## Timeouts

    Thirty seconds, then abort. The abort marker is zarquontimeout.
    """

    private static func registerAndAuth(client: some TestClientProtocol) async throws -> UUID {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(
            string: #"{"email":"chunk-\#(suffix)@test.luminavault","username":"chunk\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
        )
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { response in
            let decoder = testJSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(AuthResponse.self, from: Data(buffer: response.body)).userId
        }
    }

    private static func insertVaultFile(fluent: Fluent, tenantID: UUID, path: String) async throws -> UUID {
        let row = VaultFile(
            tenantID: tenantID,
            path: path,
            contentType: "text/markdown",
            sizeBytes: 0,
            sha256: String(repeating: "0", count: 64)
        )
        try await row.save(on: fluent.db())
        return try row.requireID()
    }

    /// Seed one chunk-indexed document and return its memory id.
    @discardableResult
    private static func seed(
        fluent: Fluent,
        tenantID: UUID,
        path: String,
        content: String = document
    ) async throws -> UUID {
        let embeddings = DeterministicEmbeddingService()
        let memories = MemoryRepository(fluent: fluent)
        let vaultFileID = try await insertVaultFile(fluent: fluent, tenantID: tenantID, path: path)
        let memory = try await memories.create(
            tenantID: tenantID,
            content: content,
            embedding: try await embeddings.embed(content, tenantID: tenantID),
            sourceVaultFileID: vaultFileID
        )
        let memoryID = try memory.requireID()
        let indexer = DocumentChunkIndexer(
            chunks: MemoryChunkRepository(fluent: fluent),
            embeddings: embeddings,
            logger: Logger(label: "test.chunk.indexer")
        )
        let written = try await indexer.index(
            tenantID: tenantID,
            memoryID: memoryID,
            vaultFileID: vaultFileID,
            spaceID: nil,
            sourcePath: path,
            content: content
        )
        #expect(written > 0, "seeding must produce chunks")
        return memoryID
    }

    private static func search(
        fluent: Fluent,
        tenantID: UUID,
        query: String,
        limit: Int = 5
    ) async throws -> [MemorySearchResult] {
        let embeddings = DeterministicEmbeddingService()
        return try await MemoryChunkRepository(fluent: fluent).hybridSearch(
            tenantID: tenantID,
            query: query,
            queryEmbedding: try await embeddings.embed(query, tenantID: tenantID),
            limit: limit
        )
    }

    // MARK: - The load-bearing assertion

    @Test
    func `a citation points at source lines that really contain the match`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tenantID = try await Self.registerAndAuth(client: client)
            try await withTestFluent(label: "test.chunk.search") { fluent in
                try await Self.seed(fluent: fluent, tenantID: tenantID, path: "projects/hermes.md")

                let hits = try await Self.search(fluent: fluent, tenantID: tenantID, query: "zarquonfallback")
                let hit = try #require(hits.first, "the lexical arm must find a rare exact token")
                let citation = try #require(hit.citation, "a chunk hit must carry a citation")

                #expect(citation.path == "projects/hermes.md")
                #expect(citation.headingPath == ["Hermes routing", "Fallbacks"])

                // Follow the citation the way a user would: open the file,
                // read exactly the lines it names.
                let lines = Self.document.components(separatedBy: "\n")
                #expect(citation.startLine >= 1)
                #expect(citation.endLine <= lines.count)
                let cited = lines[(citation.startLine - 1)...(citation.endLine - 1)].joined(separator: "\n")
                #expect(cited.contains("zarquonfallback"), "cited lines must contain the term that matched")
            }
        }
    }

    @Test
    func `different sections of one document cite different line ranges`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tenantID = try await Self.registerAndAuth(client: client)
            try await withTestFluent(label: "test.chunk.sections") { fluent in
                try await Self.seed(fluent: fluent, tenantID: tenantID, path: "projects/hermes.md")

                let fallback = try #require(
                    try await Self.search(fluent: fluent, tenantID: tenantID, query: "zarquonfallback").first?.citation
                )
                let timeout = try #require(
                    try await Self.search(fluent: fluent, tenantID: tenantID, query: "zarquontimeout").first?.citation
                )
                #expect(fallback.startLine != timeout.startLine)
                #expect(fallback.headingPath == ["Hermes routing", "Fallbacks"])
                #expect(timeout.headingPath == ["Hermes routing", "Timeouts"])
            }
        }
    }

    // MARK: - Why hybrid, not dense-only

    @Test
    func `an exact rare token is found even though the embedding carries no signal`() async throws {
        // `DeterministicEmbeddingService` produces vectors with no semantic
        // meaning, so anything this finds was found lexically. That is exactly
        // the class of query — hostnames, error codes, IDs, names — dense-only
        // retrieval was losing.
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tenantID = try await Self.registerAndAuth(client: client)
            try await withTestFluent(label: "test.chunk.lexical") { fluent in
                try await Self.seed(fluent: fluent, tenantID: tenantID, path: "notes/a.md")
                let hits = try await Self.search(fluent: fluent, tenantID: tenantID, query: "zarquontimeout")
                #expect(!hits.isEmpty)
                #expect(hits.contains { $0.content.contains("zarquontimeout") })
            }
        }
    }

    @Test
    func `operator-looking queries are treated as text, not syntax`() async throws {
        // `to_tsquery` would raise on these; `websearch_to_tsquery` must not.
        // A 500 on a question containing "and" or a stray quote is the failure
        // this guards.
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tenantID = try await Self.registerAndAuth(client: client)
            try await withTestFluent(label: "test.chunk.tsquery") { fluent in
                try await Self.seed(fluent: fluent, tenantID: tenantID, path: "notes/a.md")
                for query in ["fallbacks AND timeouts", "what's the \"codeword\"?", "a & b | c", "!!!", "NEAR(x, y)"] {
                    _ = try await Self.search(fluent: fluent, tenantID: tenantID, query: query)
                }
            }
        }
    }

    // MARK: - Tenancy

    @Test
    func `chunk search never crosses tenants`() async throws {
        // `memory_chunks` is queried through raw SQL, so it does not inherit
        // the `TenantModel` row filter — this is the test that keeps the
        // explicit `tenant_id` binding honest.
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tenantA = try await Self.registerAndAuth(client: client)
            let tenantB = try await Self.registerAndAuth(client: client)
            try await withTestFluent(label: "test.chunk.tenancy") { fluent in
                try await Self.seed(fluent: fluent, tenantID: tenantA, path: "a/secret.md")

                let leaked = try await Self.search(fluent: fluent, tenantID: tenantB, query: "zarquonfallback")
                #expect(leaked.isEmpty, "tenant B must not see tenant A's chunks")

                let own = try await Self.search(fluent: fluent, tenantID: tenantA, query: "zarquonfallback")
                #expect(!own.isEmpty, "tenant A must still see its own")
            }
        }
    }

    // MARK: - Rewrite semantics

    @Test
    func `re-indexing a shortened document leaves no stale chunks behind`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tenantID = try await Self.registerAndAuth(client: client)
            try await withTestFluent(label: "test.chunk.rewrite") { fluent in
                let memoryID = try await Self.seed(fluent: fluent, tenantID: tenantID, path: "notes/a.md")

                #expect(!(try await Self.search(fluent: fluent, tenantID: tenantID, query: "zarquontimeout").isEmpty))

                // Rewrite with the Timeouts section removed.
                let indexer = DocumentChunkIndexer(
                    chunks: MemoryChunkRepository(fluent: fluent),
                    embeddings: DeterministicEmbeddingService(),
                    logger: Logger(label: "test.chunk.indexer")
                )
                try await indexer.index(
                    tenantID: tenantID,
                    memoryID: memoryID,
                    vaultFileID: nil,
                    spaceID: nil,
                    sourcePath: "notes/a.md",
                    content: "# Hermes routing\n\nOnly this remains.\n"
                )

                // Asserting "no results" would be wrong: the dense arm is a
                // k-nearest-neighbour scan with no distance threshold, so a
                // query always returns the closest chunks even when nothing
                // matches lexically. The real invariant is that the removed
                // text is gone from the index, not that the query comes back
                // empty.
                let stale = try await Self.search(fluent: fluent, tenantID: tenantID, query: "zarquontimeout")
                #expect(
                    !stale.contains { $0.content.contains("zarquontimeout") },
                    "the removed section must no longer be retrievable"
                )
                #expect(
                    stale.allSatisfy { $0.content.contains("Only this remains") },
                    "only the rewritten chunks may survive"
                )
            }
        }
    }

    @Test
    func `backfill is idempotent and skips already-indexed memories`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tenantID = try await Self.registerAndAuth(client: client)
            try await withTestFluent(label: "test.chunk.backfill") { fluent in
                try await Self.seed(fluent: fluent, tenantID: tenantID, path: "notes/a.md")

                let backfill = ChunkBackfillService(
                    fluent: fluent,
                    vaultPaths: VaultPathService(rootPath: FileManager.default.temporaryDirectory.path),
                    indexer: DocumentChunkIndexer(
                        chunks: MemoryChunkRepository(fluent: fluent),
                        embeddings: DeterministicEmbeddingService(),
                        logger: Logger(label: "test.chunk.indexer")
                    ),
                    logger: Logger(label: "test.chunk.backfill")
                )
                let result = try await backfill.backfill(tenantID: tenantID)
                #expect(result.scanned == 0, "an already-chunked memory must not be re-embedded")
            }
        }
    }
}
