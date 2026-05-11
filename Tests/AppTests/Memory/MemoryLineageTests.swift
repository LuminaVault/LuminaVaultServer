@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import Logging
import Testing

/// HER-150 E2E tests for memory lineage: `GET /v1/memory/{id}/lineage`.
///
/// Drives the repository write path directly (bypassing the Hermes agent
/// loop) so the tool-plumbing layer and the read endpoint can be exercised
/// independently. Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct MemoryLineageTests {
    private static func decodeAuth(_ buf: ByteBuffer) throws -> AuthResponse {
        let d = testJSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(AuthResponse.self, from: Data(buffer: buf))
    }

    private static func decodeLineage(_ buf: ByteBuffer) throws -> MemoryLineageResponse {
        let d = testJSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(MemoryLineageResponse.self, from: Data(buffer: buf))
    }

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: #"{"email":"\#(email)","username":"\#(username)","password":"\#(password)"}"#)
    }

    private static func registerAndAuth(client: some TestClientProtocol) async throws -> (token: String, tenantID: UUID) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let email = "lineage-\(suffix)@test.luminavault"
        let username = "lineage\(suffix)"
        let resp = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: email, username: username, password: "CorrectHorseBatteryStaple1!"),
        ) { try decodeAuth($0.body) }
        return (resp.accessToken, resp.userId)
    }

    private static func openFluent() async throws -> Fluent {
        let fluent = Fluent(logger: Logger(label: "test.lineage.fluent"))
        fluent.databases.use(
            .postgres(configuration: TestPostgres.configuration()),
            as: .psql,
        )
        return fluent
    }

    /// Inserts a `vault_files` row directly so the lineage test doesn't have
    /// to drive the upload endpoint (which depends on the on-disk vault and
    /// is covered by VaultCRUDTests). SHA-256 + size are placeholders — the
    /// lineage endpoint only reads `id`, `path`, and `created_at`.
    private static func insertVaultFile(fluent: Fluent, tenantID: UUID, path: String) async throws -> UUID {
        let row = VaultFile(
            tenantID: tenantID,
            path: path,
            contentType: "text/markdown",
            sizeBytes: 0,
            sha256: String(repeating: "0", count: 64),
        )
        try await row.save(on: fluent.db())
        return try row.requireID()
    }

    @Test
    func `lineage returns source when linked`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, tenantID) = try await Self.registerAndAuth(client: client)

            let fluent = try await Self.openFluent()
            defer { Task { try? await fluent.shutdown() } }
            let repo = MemoryRepository(fluent: fluent)

            let vaultFileID = try await Self.insertVaultFile(
                fluent: fluent,
                tenantID: tenantID,
                path: "notes/2026-05-11-standup.md",
            )

            // Embed-less write so we don't need the real embedding service.
            // 1536 zeros matches the configured pgvector dim.
            let memory = try await repo.create(
                tenantID: tenantID,
                content: "Met with infra team about migrations.",
                embedding: Array(repeating: Float(0), count: 1536),
                sourceVaultFileID: vaultFileID,
            )
            let memoryID = try memory.requireID()

            try await client.execute(
                uri: "/v1/memory/\(memoryID)/lineage",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let body = try Self.decodeLineage(response.body)
                #expect(body.memoryId == memoryID)
                #expect(body.source?.vaultFileId == vaultFileID)
                #expect(body.source?.path == "notes/2026-05-11-standup.md")
                #expect(body.trace.contains("notes/2026-05-11-standup.md"))
                #expect(body.trace.contains("Hermes learned"))
            }
        }
    }

    @Test
    func `lineage returns null source for unlinked memory`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, tenantID) = try await Self.registerAndAuth(client: client)

            let fluent = try await Self.openFluent()
            defer { Task { try? await fluent.shutdown() } }
            let repo = MemoryRepository(fluent: fluent)

            let memory = try await repo.create(
                tenantID: tenantID,
                content: "Random thought, no source.",
                embedding: Array(repeating: Float(0), count: 1536),
            )
            let memoryID = try memory.requireID()

            try await client.execute(
                uri: "/v1/memory/\(memoryID)/lineage",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let body = try Self.decodeLineage(response.body)
                #expect(body.memoryId == memoryID)
                #expect(body.source == nil)
                #expect(body.trace.contains("no source file"))
            }
        }
    }

    @Test
    func `lineage 404 for unknown memory`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, _) = try await Self.registerAndAuth(client: client)
            try await client.execute(
                uri: "/v1/memory/\(UUID())/lineage",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func `lineage 404 for cross tenant memory`() async throws {
        // Insert a memory under tenant A, request lineage as tenant B.
        // Tenancy isolation must produce 404, not 200-with-payload.
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (_, tenantA) = try await Self.registerAndAuth(client: client)
            let (tokenB, _) = try await Self.registerAndAuth(client: client)

            let fluent = try await Self.openFluent()
            defer { Task { try? await fluent.shutdown() } }
            let repo = MemoryRepository(fluent: fluent)

            let memory = try await repo.create(
                tenantID: tenantA,
                content: "Tenant A secret.",
                embedding: Array(repeating: Float(0), count: 1536),
            )
            let memoryID = try memory.requireID()

            try await client.execute(
                uri: "/v1/memory/\(memoryID)/lineage",
                method: .get,
                headers: [.authorization: "Bearer \(tokenB)"],
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
