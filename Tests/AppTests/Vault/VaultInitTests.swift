@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import struct LuminaVaultShared.AuthResponse
import struct LuminaVaultShared.SpaceListResponse
import struct LuminaVaultShared.VaultStatusResponse
import Testing

/// HER-35 — end-to-end coverage for the new `POST /v1/vault/create` +
/// `GET /v1/vault/status` handshake. Boots the full Hummingbird app + Postgres
/// so the M37 migration, `User.vaultInitialized`, `VaultInitService`, and the
/// SOUL bootstrap decouple are all exercised together. Run with
/// `docker compose up -d postgres`.
@Suite(.serialized)
struct VaultInitTests {
    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func decodeAuth(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeStatus(_ buffer: ByteBuffer) throws -> VaultStatusResponse {
        try testJSONDecoder().decode(VaultStatusResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeSpaces(_ buffer: ByteBuffer) throws -> SpaceListResponse {
        try testJSONDecoder().decode(SpaceListResponse.self, from: Data(buffer: buffer))
    }

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("vault-\(suffix)@test.luminavault", "vault-\(suffix)")
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

    @Test
    func `registration leaves vault uninitialized`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.registerAndAuth(client: client)
            #expect(auth.vaultInitialized == false)

            let status = try await client.execute(
                uri: "/v1/vault/status",
                method: .get,
                headers: [.authorization: "Bearer \(auth.accessToken)"],
            ) { try Self.decodeStatus($0.body) }
            #expect(status.initialized == false)
            #expect(status.defaultSpaceSlugs.isEmpty)
        }
    }

    @Test
    func `vault create flips flag, seeds defaults, idempotent on rerun`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.registerAndAuth(client: client)
            let token = auth.accessToken

            // First create — should flip the flag and seed defaults.
            let first = try await client.execute(
                uri: "/v1/vault/create",
                method: .post,
                headers: [.authorization: "Bearer \(token)"],
            ) { try Self.decodeStatus($0.body) }
            #expect(first.initialized == true)
            #expect(Set(first.defaultSpaceSlugs) == Set(SpaceDefaults.entries.map(\.slug)))

            // Listing spaces should surface the seeded set.
            let listed = try await client.execute(
                uri: "/v1/spaces",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { try Self.decodeSpaces($0.body) }
            let listedSlugs = Set(listed.spaces.map(\.slug))
            #expect(Set(SpaceDefaults.entries.map(\.slug)).isSubset(of: listedSlugs))

            // Second create — must be idempotent (no duplicate-slug failure).
            let second = try await client.execute(
                uri: "/v1/vault/create",
                method: .post,
                headers: [.authorization: "Bearer \(token)"],
            ) { try Self.decodeStatus($0.body) }
            #expect(second.initialized == true)
        }
    }

    @Test
    func `auth response carries vaultInitialized for legacy and post-create users`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            // Fresh register: should report vaultInitialized = false.
            let preCreate = try await Self.registerAndAuth(client: client)
            #expect(preCreate.vaultInitialized == false)

            // After /vault/create, status is true. Subsequent refresh should
            // observe the new flag.
            _ = try await client.execute(
                uri: "/v1/vault/create",
                method: .post,
                headers: [.authorization: "Bearer \(preCreate.accessToken)"],
            ) { try Self.decodeStatus($0.body) }

            let status = try await client.execute(
                uri: "/v1/vault/status",
                method: .get,
                headers: [.authorization: "Bearer \(preCreate.accessToken)"],
            ) { try Self.decodeStatus($0.body) }
            #expect(status.initialized == true)
            #expect(status.defaultSpaceSlugs.count == SpaceDefaults.entries.count)
        }
    }
}
