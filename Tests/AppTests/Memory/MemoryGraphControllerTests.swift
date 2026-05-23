@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// HER-235 — HTTP-surface tests for `GET /v1/memory/graph`. Drives the
/// public router via `app.test(.router)` so auth + middleware + query-param
/// clamping are exercised end-to-end. Service-level derivation logic is
/// covered by `MemoryGraphServiceTests`.
@Suite(.serialized)
struct MemoryGraphControllerTests {
    private static let dim = 1536

    private static func basis(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[axis] = 1
        return v
    }

    private static func decodeAuth(_ buf: ByteBuffer) throws -> AuthResponse {
        let d = testJSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(AuthResponse.self, from: Data(buffer: buf))
    }

    private static func decodeGraph(_ buf: ByteBuffer) throws -> MemoryGraphResponse {
        let d = testJSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(MemoryGraphResponse.self, from: Data(buffer: buf))
    }

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: #"{"email":"\#(email)","username":"\#(username)","password":"\#(password)"}"#)
    }

    private static func registerAndAuth(client: some TestClientProtocol) async throws -> (token: String, tenantID: UUID) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let resp = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(
                email: "graph-\(suffix)@test.luminavault",
                username: "graph\(suffix)",
                password: "CorrectHorseBatteryStaple1!",
            ),
        ) { try decodeAuth($0.body) }
        return (resp.accessToken, resp.userId)
    }

    @Test
    func `graph returns nodes and edges for authed tenant`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, tenantID) = try await Self.registerAndAuth(client: client)
            try await withTestFluent(label: "test.graph.controller.happy") { fluent in
                let repo = MemoryRepository(fluent: fluent)
                _ = try await repo.create(tenantID: tenantID, content: "Note 1", embedding: Self.basis(0), tags: ["theme-a"])
                _ = try await repo.create(tenantID: tenantID, content: "Note 2", embedding: Self.basis(0), tags: ["theme-a"])
            }
            try await client.execute(
                uri: "/v1/memory/graph",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let body = try Self.decodeGraph(response.body)
                #expect(body.nodes.count == 2)
                // Two memories share a tag and have identical embeddings — both
                // derivation paths should fire. After tag wins the dedupe race
                // exactly one edge survives.
                #expect(body.edges.count == 1)
            }
        }
    }

    @Test
    func `graph returns 401 without auth header`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/memory/graph",
                method: .get,
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `graph clamps out-of-range query params`() async throws {
        // limit > MemoryGraphService.maxLimit should clamp to maxLimit and
        // still produce a valid 200 response (rather than 400).
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, _) = try await Self.registerAndAuth(client: client)
            try await client.execute(
                uri: "/v1/memory/graph?limit=9999&similarityThreshold=2.0&maxEdgesPerNode=0",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let body = try Self.decodeGraph(response.body)
                #expect(body.nodes.isEmpty)
            }
        }
    }
}
