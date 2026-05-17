@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import struct LuminaVaultShared.AuthResponse
import struct LuminaVaultShared.CreateSpaceRequest
import struct LuminaVaultShared.SpaceDTO
import struct LuminaVaultShared.SpaceListResponse
import struct LuminaVaultShared.UpdateSpaceRequest
import Testing

/// HER-35 — verifies the new `category` column threads through the Spaces
/// CRUD surface and that the seeded defaults (`SpaceDefaults.entries`) land
/// with their slug as the category bucket label.
@Suite(.serialized)
struct SpacesCategoryTests {
    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func decodeAuth(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeSpace(_ buffer: ByteBuffer) throws -> SpaceDTO {
        try testJSONDecoder().decode(SpaceDTO.self, from: Data(buffer: buffer))
    }

    private static func decodeList(_ buffer: ByteBuffer) throws -> SpaceListResponse {
        try testJSONDecoder().decode(SpaceListResponse.self, from: Data(buffer: buffer))
    }

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("space-\(suffix)@test.luminavault", "space-\(suffix)")
    }

    private static func registerAndAuth(client: some TestClientProtocol) async throws -> AuthResponse {
        let (email, username) = randomUser()
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: email, username: username, password: "CorrectHorseBatteryStaple1!"),
        ) { try Self.decodeAuth($0.body) }
    }

    private static func encode(_ value: some Encodable) throws -> ByteBuffer {
        try ByteBuffer(data: JSONEncoder().encode(value))
    }

    @Test
    func `create space accepts and persists category`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.registerAndAuth(client: client)
            let token = auth.accessToken
            let create = CreateSpaceRequest(
                name: "Crypto",
                slug: "crypto",
                description: nil,
                color: nil,
                icon: "bitcoinsign.circle",
                category: "stocks",
            )
            let created = try await client.execute(
                uri: "/v1/spaces",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: try Self.encode(create),
            ) { try Self.decodeSpace($0.body) }
            #expect(created.category == "stocks")
            #expect(created.noteCount == 0)
            #expect(created.icon == "bitcoinsign.circle")
        }
    }

    @Test
    func `update space changes category and clears via empty string`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.registerAndAuth(client: client)
            let token = auth.accessToken

            let created = try await client.execute(
                uri: "/v1/spaces",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: try Self.encode(CreateSpaceRequest(
                    name: "Reading",
                    slug: "reading",
                    description: nil,
                    color: nil,
                    icon: "book.fill",
                    category: "ideas",
                )),
            ) { try Self.decodeSpace($0.body) }

            // Move category from "ideas" → "work".
            let moved = try await client.execute(
                uri: "/v1/spaces/\(created.id)",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: try Self.encode(UpdateSpaceRequest(category: "work")),
            ) { try Self.decodeSpace($0.body) }
            #expect(moved.category == "work")

            // Empty string clears the category.
            let cleared = try await client.execute(
                uri: "/v1/spaces/\(created.id)",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: try Self.encode(UpdateSpaceRequest(category: "")),
            ) { try Self.decodeSpace($0.body) }
            #expect(cleared.category == nil)
        }
    }

    @Test
    func `seeded defaults expose slug as category`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.registerAndAuth(client: client)
            let token = auth.accessToken
            _ = try await client.execute(
                uri: "/v1/vault/create",
                method: .post,
                headers: [.authorization: "Bearer \(token)"],
            ) { $0 }

            let listed = try await client.execute(
                uri: "/v1/spaces",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { try Self.decodeList($0.body) }

            for entry in SpaceDefaults.entries {
                let match = listed.spaces.first(where: { $0.slug == entry.slug })
                #expect(match != nil, "missing seeded slug \(entry.slug)")
                #expect(match?.category == entry.slug, "category should mirror slug for seeded space \(entry.slug)")
            }
        }
    }
}
