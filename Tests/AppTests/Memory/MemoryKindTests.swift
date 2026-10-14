@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// A memory can say what kind of statement it is — a preference, a decision,
/// a fact, or a note — so a user (and an agent) can find "what did I decide"
/// without reading every note. Unclassified stays the default: nothing
/// guesses a kind for a memory nobody classified.
///
/// Run with `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct MemoryKindTests {
    private static func register(client: some TestClientProtocol) async throws -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(
            string: #"{"email":"kind-\#(suffix)@test.luminavault","username":"kind\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
        )
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)).accessToken }
    }

    private static func upsert(
        client: some TestClientProtocol,
        token: String,
        content: String,
        kind: String? = nil
    ) async throws -> UUID {
        let kindField = kind.map { #","kind":"\#($0)""# } ?? ""
        return try await client.execute(
            uri: "/v1/memory/upsert",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(string: #"{"content":"\#(content)"\#(kindField)}"#)
        ) { try testJSONDecoder().decode(MemoryUpsertResponse.self, from: Data($0.body.readableBytesView)).memoryId }
    }

    private static func list(client: some TestClientProtocol, token: String, query: String) async throws -> (HTTPResponse.Status, [MemoryDTO]) {
        try await client.execute(
            uri: "/v1/memory?\(query)",
            method: .get,
            headers: [.authorization: "Bearer \(token)"]
        ) { response in
            guard response.status == .ok else { return (response.status, []) }
            let list = try testJSONDecoder().decode(MemoryListResponse.self, from: Data(response.body.readableBytesView))
            return (response.status, list.memories)
        }
    }

    @Test
    func `a saved kind comes back and filters the list`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let preference = try await Self.upsert(client: client, token: token, content: "Prefers tea.", kind: "preference")
            let plain = try await Self.upsert(client: client, token: token, content: "Bought milk.")

            let (_, all) = try await Self.list(client: client, token: token, query: "limit=50")
            #expect(all.first { $0.id == preference }?.kind == .preference)
            #expect(all.first { $0.id == plain }?.kind == nil)

            let (_, preferences) = try await Self.list(client: client, token: token, query: "kind=preference")
            #expect(preferences.map(\.id) == [preference])

            let (status, _) = try await Self.list(client: client, token: token, query: "kind=hunch")
            #expect(status == .badRequest)
        }
    }

    @Test
    func `the kind can be set on its own and the change is attributed to the user`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let id = try await Self.upsert(client: client, token: token, content: "We ship on Tuesdays.")

            let patched: MemoryDTO = try await client.execute(
                uri: "/v1/memory/\(id)",
                method: .patch,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"kind":"decision"}"#)
            ) { response in
                #expect(response.status == .ok)
                return try testJSONDecoder().decode(MemoryDTO.self, from: Data(response.body.readableBytesView))
            }
            #expect(patched.kind == .decision)
            #expect(patched.content == "We ship on Tuesdays.")

            let provenance: MemoryProvenanceResponse = try await client.execute(
                uri: "/v1/memory/\(id)/provenance",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { try testJSONDecoder().decode(MemoryProvenanceResponse.self, from: Data($0.body.readableBytesView)) }
            #expect(provenance.contributions.map(\.operation) == [.create, .update])
            #expect(provenance.contributions.last?.actor == .user)
        }
    }
}
