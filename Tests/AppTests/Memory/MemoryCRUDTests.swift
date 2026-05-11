import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import App

/// End-to-end tests for HER-89 memory CRUD endpoints
/// (`GET /v1/memory`, `GET /v1/memory/:id`, `DELETE /v1/memory/:id`,
/// `PATCH /v1/memory/:id`). Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct MemoryCRUDTests {

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func decodeAuthResponse(_ buffer: ByteBuffer) throws -> AuthResponse {
        try JSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeUpsert(_ buffer: ByteBuffer) throws -> MemoryUpsertResponse {
        try JSONDecoder().decode(MemoryUpsertResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeList(_ buffer: ByteBuffer) throws -> MemoryListResponse {
        try JSONDecoder().decode(MemoryListResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeOne(_ buffer: ByteBuffer) throws -> MemoryDTO {
        try JSONDecoder().decode(MemoryDTO.self, from: Data(buffer: buffer))
    }

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("mem-\(suffix)@test.luminavault", "mem-\(suffix)")
    }

    private static func registerAndAuth(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        let resp = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: email, username: username, password: "CorrectHorseBatteryStaple1!")
        ) { try decodeAuthResponse($0.body) }
        return resp.accessToken
    }

    private static func upsertMemory(client: some TestClientProtocol, token: String, content: String) async throws -> UUID {
        let body = ByteBuffer(string: #"{"content":"\#(content)"}"#)
        return try await client.execute(
            uri: "/v1/memory/upsert",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: body
        ) { try decodeUpsert($0.body).memoryId }
    }

    @Test
    func listReturnsAllMemoriesForTenant() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            _ = try await Self.upsertMemory(client: client, token: token, content: "first memory")
            _ = try await Self.upsertMemory(client: client, token: token, content: "second memory")

            try await client.execute(
                uri: "/v1/memory",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let list = try Self.decodeList(response.body)
                #expect(list.memories.count >= 2)
                #expect(list.limit == 20)
                #expect(list.offset == 0)
            }
        }
    }

    @Test
    func listSupportsLimitAndOffset() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            for i in 0..<3 {
                _ = try await Self.upsertMemory(client: client, token: token, content: "memo \(i)")
            }
            try await client.execute(
                uri: "/v1/memory?limit=2&offset=0",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let list = try Self.decodeList(response.body)
                #expect(list.memories.count == 2)
                #expect(list.limit == 2)
                #expect(list.offset == 0)
            }
        }
    }

    @Test
    func listRejectsSpaceFilterUntilHER105() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await client.execute(
                uri: "/v1/memory?space=stocks",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .notImplemented)
            }
        }
    }

    @Test
    func patchUpdatesContentAndReembeds() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let id = try await Self.upsertMemory(client: client, token: token, content: "before edit")

            let body = ByteBuffer(string: #"{"content":"after edit"}"#)
            try await client.execute(
                uri: "/v1/memory/\(id.uuidString)",
                method: .patch,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body
            ) { response in
                #expect(response.status == .ok)
                let dto = try Self.decodeOne(response.body)
                #expect(dto.id == id)
                #expect(dto.content == "after edit")
            }
        }
    }

    @Test
    func patchTagsRoundTrips() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let id = try await Self.upsertMemory(client: client, token: token, content: "taggable")
            let body = ByteBuffer(string: #"{"tags":["work","ai"]}"#)
            try await client.execute(
                uri: "/v1/memory/\(id.uuidString)",
                method: .patch,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body
            ) { response in
                #expect(response.status == .ok)
                let dto = try Self.decodeOne(response.body)
                #expect(Set(dto.tags) == Set(["work", "ai"]))
            }
            try await client.execute(
                uri: "/v1/memory?tag=ai",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let list = try Self.decodeList(response.body)
                #expect(list.memories.contains(where: { $0.id == id }))
            }
        }
    }

    @Test
    func patchEmptyBodyReturns400() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let id = try await Self.upsertMemory(client: client, token: token, content: "no-op patch")
            try await client.execute(
                uri: "/v1/memory/\(id.uuidString)",
                method: .patch,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(string: "{}")
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test
    func deleteRemovesMemoryAndIsIdempotent() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let id = try await Self.upsertMemory(client: client, token: token, content: "to delete")
            try await client.execute(
                uri: "/v1/memory/\(id.uuidString)",
                method: .delete,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .noContent)
            }
            try await client.execute(
                uri: "/v1/memory/\(id.uuidString)",
                method: .delete,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func tenantIsolationDeleteIsScoped() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let alice = try await Self.registerAndAuth(client: client)
            let mallory = try await Self.registerAndAuth(client: client)
            let aliceMem = try await Self.upsertMemory(client: client, token: alice, content: "alice's secret")

            // Mallory cannot delete Alice's memory.
            try await client.execute(
                uri: "/v1/memory/\(aliceMem.uuidString)",
                method: .delete,
                headers: [.authorization: "Bearer \(mallory)"]
            ) { response in
                #expect(response.status == .notFound)
            }
            // Still readable by Alice.
            try await client.execute(
                uri: "/v1/memory/\(aliceMem.uuidString)",
                method: .get,
                headers: [.authorization: "Bearer \(alice)"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test
    func unauthenticatedReturns401() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/memory", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }
}
