@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import LuminaVaultShared
import SQLKit
import Testing

/// `GET /v1/memory/{id}/related` answers from the stored embedding, keeps
/// only real connections (the distance floor), never shows the memory itself
/// or another tenant's, and does not count as recall. A note upload hands
/// back the memory id the client then asks about.
///
/// Run with `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct MemoryRelatedTests {
    private struct Account {
        let userID: UUID
        let token: String
    }

    private static func register(client: some TestClientProtocol) async throws -> Account {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(
            string: #"{"email":"related-\#(suffix)@test.luminavault","username":"related\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
        )
        let auth = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)) }
        return Account(userID: auth.userId, token: auth.accessToken)
    }

    private static func related(
        client: some TestClientProtocol,
        token: String,
        id: UUID,
        query: String = ""
    ) async throws -> (HTTPResponse.Status, MemoryRelatedResponse?) {
        try await client.execute(
            uri: "/v1/memory/\(id)/related\(query)",
            method: .get,
            headers: [.authorization: "Bearer \(token)"]
        ) { response in
            guard response.status == .ok else { return (response.status, nil) }
            return try (response.status, testJSONDecoder().decode(MemoryRelatedResponse.self, from: Data(response.body.readableBytesView)))
        }
    }

    /// A unit vector at cosine `similarity` to axis 0, leaning on `axis`.
    private static func vector(similarity: Float, axis: Int = 1) -> [Float] {
        var v = [Float](repeating: 0, count: 1536)
        v[0] = similarity
        v[axis] = (1 - similarity * similarity).squareRoot()
        return v
    }

    private static func memory(
        fluent: Fluent,
        tenantID: UUID,
        content: String,
        embedding: [Float],
        reviewState: String = MemoryReviewState.auto,
        kind: MemoryKindDTO? = nil
    ) async throws -> UUID {
        try await MemoryRepository(fluent: fluent).create(
            tenantID: tenantID,
            content: content,
            embedding: embedding,
            reviewState: reviewState,
            kind: kind
        ).requireID()
    }

    private static func hitCount(fluent: Fluent, id: UUID) async throws -> Int64 {
        try #require(try await Memory.find(id, on: fluent.db())).queryHitCount
    }

    @Test
    func `returns close memories only, never itself, rejected ones or other tenants'`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let owner = try await Self.register(client: client)
            let stranger = try await Self.register(client: client)
            try await withTestFluent(label: "test.memory.related") { fluent in
                let base = try await Self.memory(
                    fluent: fluent, tenantID: owner.userID, content: "Ship on Tuesdays.", embedding: Self.vector(similarity: 1)
                )
                let longText = "We release every Tuesday after QA signs off on Monday. " + String(repeating: "More detail. ", count: 30)
                let near = try await Self.memory(
                    fluent: fluent, tenantID: owner.userID, content: longText,
                    embedding: Self.vector(similarity: 0.95), kind: .decision
                )
                let closer = try await Self.memory(
                    fluent: fluent, tenantID: owner.userID, content: "Tuesday is ship day.",
                    embedding: Self.vector(similarity: 0.99, axis: 2)
                )
                // Distance 0.5: past the 0.45 floor.
                _ = try await Self.memory(
                    fluent: fluent, tenantID: owner.userID, content: "Loosely related.", embedding: Self.vector(similarity: 0.5)
                )
                _ = try await Self.memory(
                    fluent: fluent, tenantID: owner.userID, content: "Unrelated.", embedding: Self.vector(similarity: 0, axis: 3)
                )
                _ = try await Self.memory(
                    fluent: fluent, tenantID: owner.userID, content: "Rejected twin.",
                    embedding: Self.vector(similarity: 0.98), reviewState: MemoryReviewState.rejected
                )
                // Another tenant's identical memory never shows up.
                _ = try await Self.memory(
                    fluent: fluent, tenantID: stranger.userID, content: "Ship on Tuesdays.", embedding: Self.vector(similarity: 1)
                )

                let (status, body) = try await Self.related(client: client, token: owner.token, id: base)
                #expect(status == .ok)
                let response = try #require(body)
                #expect(response.memoryId == base)
                #expect(response.items.map(\.id) == [closer, near])
                let first = try #require(response.items.first)
                #expect(abs(first.similarity - 0.99) < 0.001)
                let second = try #require(response.items.last)
                #expect(second.kind == .decision)
                #expect(second.snippet.count == 160)
                #expect(second.snippet.hasSuffix("…"))
                #expect(!second.snippet.contains("\n"))

                let (_, limited) = try await Self.related(client: client, token: owner.token, id: base, query: "?limit=1")
                #expect(limited?.items.map(\.id) == [closer])

                // Not recall: nothing shown here gets a query hit.
                try await Task.sleep(for: .milliseconds(300))
                #expect(try await Self.hitCount(fluent: fluent, id: near) == 0)
                #expect(try await Self.hitCount(fluent: fluent, id: closer) == 0)

                let (strangerStatus, _) = try await Self.related(client: client, token: stranger.token, id: base)
                #expect(strangerStatus == .notFound)
                let (missingStatus, _) = try await Self.related(client: client, token: owner.token, id: UUID())
                #expect(missingStatus == .notFound)
            }
        }
    }

    /// The flag is what keeps related lookups out of hit counts; a normal
    /// search still counts.
    @Test
    func `semanticSearch counts hits unless told not to`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let owner = try await Self.register(client: client)
            try await withTestFluent(label: "test.memory.related.hits") { fluent in
                let id = try await Self.memory(
                    fluent: fluent, tenantID: owner.userID, content: "Counted.", embedding: Self.vector(similarity: 1)
                )
                let repository = MemoryRepository(fluent: fluent)
                _ = try await repository.semanticSearch(
                    tenantID: owner.userID, queryEmbedding: Self.vector(similarity: 1), limit: 5, countHits: false
                )
                #expect(try await Self.hitCount(fluent: fluent, id: id) == 0)
                _ = try await repository.semanticSearch(
                    tenantID: owner.userID, queryEmbedding: Self.vector(similarity: 1), limit: 5
                )
                #expect(try await Self.hitCount(fluent: fluent, id: id) == 1)
            }
        }
    }

    @Test
    func `a note upload returns its memory id, a plain file does not`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let owner = try await Self.register(client: client)
            func upload(_ path: String, _ text: String, note: Bool) async throws -> VaultUploadResponse {
                try await client.execute(
                    uri: "/v1/vault/files?path=\(path)\(note ? "&note=true" : "")",
                    method: .post,
                    headers: [.authorization: "Bearer \(owner.token)", .contentType: "text/markdown"],
                    body: ByteBuffer(string: text)
                ) { response in
                    #expect(response.status == .ok || response.status == .created)
                    return try testJSONDecoder().decode(VaultUploadResponse.self, from: Data(response.body.readableBytesView))
                }
            }

            let first = try await upload("notes/plan.md", "Plan the launch for Tuesday.", note: true)
            let memoryID = try #require(first.memoryId)
            try await withTestFluent(label: "test.vault.upload.memoryid") { fluent in
                let memory = try #require(try await Memory.find(memoryID, on: fluent.db()))
                #expect(memory.tenantID == owner.userID)
                #expect(memory.content == "Plan the launch for Tuesday.")
            }

            // Editing the note updates the same memory.
            let edited = try await upload("notes/plan.md", "Plan the launch for Wednesday.", note: true)
            #expect(edited.memoryId == memoryID)

            let plain = try await upload("files/readme.md", "Just a file.", note: false)
            #expect(plain.memoryId == nil)

            let (status, _) = try await Self.related(client: client, token: owner.token, id: memoryID)
            #expect(status == .ok)
        }
    }
}
