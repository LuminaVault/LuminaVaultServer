@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import Logging
import LuminaVaultShared
import Testing

/// A correction has to reach every place the old text was stored.
///
/// A memory's text lives in three places: `memories.content`, its whole-memory
/// embedding, and its `memory_chunks`. Editing used to update the first two and
/// leave the chunks behind, so the chunk arm of hybrid search kept returning
/// the wording the user had just corrected. Moving a note between Space
/// folders had the same shape of bug for `space_id` and the cited path.
///
/// Run with `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct MemoryCorrectionTests {
    private static let original = """
    # Routing

    When the primary provider errors we retry once. The codeword is zarquonfallback.
    """

    private static let corrected = """
    # Routing

    We no longer retry; one provider only. The codeword is zarquonsingle.
    """

    private static func register(client: some TestClientProtocol) async throws -> AuthResponse {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(
            string: #"{"email":"fix-\#(suffix)@test.luminavault","username":"fix\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
        )
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { response in
            try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: response.body))
        }
    }

    /// A chunk-indexed memory backed by a vault file, the shape a saved note has.
    private static func seedNote(
        fluent: Fluent,
        tenantID: UUID,
        path: String,
        spaceID: UUID? = nil
    ) async throws -> UUID {
        let embeddings = DeterministicEmbeddingService()
        let file = VaultFile(
            tenantID: tenantID,
            path: path,
            contentType: "text/markdown",
            sizeBytes: 0,
            sha256: String(repeating: "0", count: 64)
        )
        file.spaceID = spaceID
        try await file.save(on: fluent.db())
        let fileID = try file.requireID()
        let memory = try await MemoryRepository(fluent: fluent).create(
            tenantID: tenantID,
            content: original,
            embedding: embeddings.embed(original, tenantID: tenantID),
            sourceVaultFileID: fileID
        )
        let memoryID = try memory.requireID()
        let written = try await DocumentChunkIndexer(
            chunks: MemoryChunkRepository(fluent: fluent),
            embeddings: embeddings,
            logger: Logger(label: "test.correction.indexer")
        ).index(
            tenantID: tenantID,
            memoryID: memoryID,
            vaultFileID: fileID,
            spaceID: spaceID,
            sourcePath: path,
            content: original
        )
        #expect(written > 0, "seeding must produce chunks")
        return memoryID
    }

    private static func chunkHits(
        fluent: Fluent,
        tenantID: UUID,
        query: String,
        spaceID: UUID? = nil
    ) async throws -> [MemorySearchResult] {
        let embeddings = DeterministicEmbeddingService()
        return try await MemoryChunkRepository(fluent: fluent).hybridSearch(
            tenantID: tenantID,
            query: query,
            queryEmbedding: embeddings.embed(query, tenantID: tenantID),
            limit: 10,
            spaceID: spaceID
        )
    }

    /// Dense search ranks every chunk, relevant or not, so "the memory came
    /// back" proves nothing on its own. What matters is whether the text a hit
    /// carries still says the thing being searched for.
    private static func carries(_ hits: [MemorySearchResult], memoryID: UUID, _ token: String) -> Bool {
        hits.contains { hit in
            hit.id == memoryID && (hit.content.contains(token) || (hit.snippet ?? "").contains(token))
        }
    }

    @Test
    func `a corrected memory stops matching its old text and matches the new text`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let tenantID = auth.userId
            try await withTestFluent(label: "test.correction") { fluent in
                let memoryID = try await Self.seedNote(fluent: fluent, tenantID: tenantID, path: "inbox/routing.md")
                let before = try #require(try await MemoryRepository(fluent: fluent).find(tenantID: tenantID, id: memoryID))
                let beforeHits = try await Self.chunkHits(fluent: fluent, tenantID: tenantID, query: "zarquonfallback")
                #expect(Self.carries(beforeHits, memoryID: memoryID, "zarquonfallback"), "the seeded text must be findable first")

                let body = try JSONEncoder().encode(["content": Self.corrected])
                try await client.execute(
                    uri: "/v1/memory/\(memoryID)",
                    method: .patch,
                    headers: [.authorization: "Bearer \(auth.accessToken)", .contentType: "application/json"],
                    body: ByteBuffer(data: body)
                ) { #expect($0.status == .ok) }

                let stale = try await Self.chunkHits(fluent: fluent, tenantID: tenantID, query: "zarquonfallback")
                #expect(!Self.carries(stale, memoryID: memoryID, "zarquonfallback"), "old wording must not survive a correction")

                let fresh = try await Self.chunkHits(fluent: fluent, tenantID: tenantID, query: "zarquonsingle")
                #expect(Self.carries(fresh, memoryID: memoryID, "zarquonsingle"), "corrected text must be chunked straight away")
                let hit = try #require(fresh.first { $0.id == memoryID })
                #expect(hit.citation != nil, "the corrected memory must come back from the chunk arm")
                #expect(hit.citation?.path == nil, "the file still holds the old text, so it is not cited")

                let after = try #require(try await MemoryRepository(fluent: fluent).find(tenantID: tenantID, id: memoryID))
                #expect(after.content == Self.corrected)
                let editedAt = try #require(after.updatedAt, "an edit must stamp updated_at")
                if let previous = before.updatedAt {
                    #expect(editedAt > previous)
                }
                #expect(after.updatedByUserID == tenantID)
            }
        }
    }

    @Test
    func `a content update from another path also drops stale chunks`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tenantID = try await Self.register(client: client).userId
            try await withTestFluent(label: "test.correction.repo") { fluent in
                let memoryID = try await Self.seedNote(fluent: fluent, tenantID: tenantID, path: "inbox/repo.md")
                let embeddings = DeterministicEmbeddingService()
                let updated = try await MemoryRepository(fluent: fluent).updateContent(
                    tenantID: tenantID,
                    id: memoryID,
                    content: Self.corrected,
                    embedding: embeddings.embed(Self.corrected, tenantID: tenantID)
                )
                #expect(updated)
                let stale = try await Self.chunkHits(fluent: fluent, tenantID: tenantID, query: "zarquonfallback")
                #expect(!Self.carries(stale, memoryID: memoryID, "zarquonfallback"))
            }
        }
    }

    @Test
    func `reading a memory does not modify it`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await withTestFluent(label: "test.correction.read") { fluent in
                let memoryID = try await Self.seedNote(fluent: fluent, tenantID: auth.userId, path: "inbox/read.md")
                let repo = MemoryRepository(fluent: fluent)
                let before = try #require(try await repo.find(tenantID: auth.userId, id: memoryID))

                try await client.execute(
                    uri: "/v1/memory/\(memoryID)",
                    method: .get,
                    headers: [.authorization: "Bearer \(auth.accessToken)"]
                ) { #expect($0.status == .ok) }

                let after = try #require(try await repo.find(tenantID: auth.userId, id: memoryID))
                #expect(after.updatedAt == before.updatedAt)
                #expect(after.updatedByUserID == before.updatedByUserID)
            }
        }
    }

    @Test
    func `moving a note into a Space folder refiles its memory and chunks`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let tenantID = auth.userId
            try await withTestFluent(label: "test.correction.move") { fluent in
                let space = Space(tenantID: tenantID, name: "Work", slug: "work")
                try await space.save(on: fluent.db())
                let spaceID = try space.requireID()
                let memoryID = try await Self.seedNote(fluent: fluent, tenantID: tenantID, path: "inbox/plan.md")

                let body = ByteBuffer(string: #"{"path":"inbox/plan.md","newPath":"work/plan.md"}"#)
                try await client.execute(
                    uri: "/v1/vault/files/move",
                    method: .post,
                    headers: [.authorization: "Bearer \(auth.accessToken)", .contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .ok)
                    let dto = try testJSONDecoder().decode(VaultFileDTO.self, from: Data(buffer: response.body))
                    #expect(dto.spaceId == spaceID)
                }

                let memory = try #require(try await MemoryRepository(fluent: fluent).find(tenantID: tenantID, id: memoryID))
                #expect(memory.spaceID == spaceID)

                let scoped = try await Self.chunkHits(fluent: fluent, tenantID: tenantID, query: "zarquonfallback", spaceID: spaceID)
                let hit = try #require(scoped.first { $0.id == memoryID }, "Space-scoped search must find the moved note")
                #expect(hit.citation?.path == "work/plan.md")

                // And back out to the inbox: unfiled again.
                let back = ByteBuffer(string: #"{"path":"work/plan.md","newPath":"inbox/plan.md"}"#)
                try await client.execute(
                    uri: "/v1/vault/files/move",
                    method: .post,
                    headers: [.authorization: "Bearer \(auth.accessToken)", .contentType: "application/json"],
                    body: back
                ) { #expect($0.status == .ok) }
                let unfiled = try #require(try await MemoryRepository(fluent: fluent).find(tenantID: tenantID, id: memoryID))
                #expect(unfiled.spaceID == nil)
            }
        }
    }
}
