@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import struct LuminaVaultShared.AuthResponse
import struct LuminaVaultShared.HermesGatewayCatalogEntry
import enum LuminaVaultShared.HermesGatewayID
import struct LuminaVaultShared.HermesGatewaysListResponse
import enum LuminaVaultShared.HermesGatewayStatus
import Testing

/// HER-241 — `/v1/me/hermes-gateways` E2E. Runs against the real router
/// + Postgres. Requires `docker compose up -d postgres`. Reuses
/// `dbTestReader` which pins `secret.masterKey` so the gateway route
/// group mounts (SecretBox needs the master key to seal config blobs).
///
/// Does NOT cover `POST .../{id}/test` — that endpoint dials the
/// user's resolved Hermes upstream and would need a `URLSession`
/// fixture. Probe behaviour is exercised in unit tests on the
/// `HermesGatewayClient` itself in a follow-up commit.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct HermesGatewaysControllerTests {
    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("gw-\(suffix)@test.luminavault", "gw-\(suffix)")
    }

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func decodeAuth(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeList(_ buffer: ByteBuffer) throws -> HermesGatewaysListResponse {
        try testJSONDecoder().decode(HermesGatewaysListResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeEntry(_ buffer: ByteBuffer) throws -> HermesGatewayCatalogEntry {
        try testJSONDecoder().decode(HermesGatewayCatalogEntry.self, from: Data(buffer: buffer))
    }

    private static func register(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        let body = registerBody(email: email, username: username, password: "CorrectHorseBatteryStaple1!")
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try decodeAuth($0.body).accessToken }
    }

    @Test
    func `GET list returns all four MVP gateways with notConfigured default`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/me/hermes-gateways",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let list = try Self.decodeList(response.body)
                #expect(list.items.count == HermesGatewayID.allCases.count)
                let ids = Set(list.items.map(\.id))
                #expect(ids == Set(HermesGatewayID.allCases))
                for item in list.items {
                    #expect(item.status == .notConfigured)
                    #expect(item.hasConfig == false)
                    #expect(item.verifiedAt == nil)
                    #expect(item.lastFailureCode == nil)
                    #expect(!item.requiredFields.isEmpty)
                }
            }
        }
    }

    @Test
    func `PUT then GET round-trips and never echoes secret config`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)

            let putBody = ByteBuffer(string: #"{"config":{"bot_token":"TELEGRAM-SECRET-XYZ-123"}}"#)
            try await client.execute(
                uri: "/v1/me/hermes-gateways/telegram",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: putBody
            ) { response in
                #expect(response.status == .ok)
                let entry = try Self.decodeEntry(response.body)
                #expect(entry.id == .telegram)
                #expect(entry.status == .configured)
                #expect(entry.hasConfig == true)
                let body = String(buffer: response.body)
                #expect(!body.contains("TELEGRAM-SECRET-XYZ-123"))
                #expect(!body.contains("bot_token"))
            }

            try await client.execute(
                uri: "/v1/me/hermes-gateways/telegram",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let entry = try Self.decodeEntry(response.body)
                #expect(entry.id == .telegram)
                #expect(entry.status == .configured)
                #expect(entry.hasConfig == true)
                let body = String(buffer: response.body)
                #expect(!body.contains("TELEGRAM-SECRET-XYZ-123"))
            }
        }
    }

    @Test
    func `PUT rejects missing required field with stable code`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            // Discord requires bot_token AND application_id — omit one.
            let putBody = ByteBuffer(string: #"{"config":{"bot_token":"abc"}}"#)
            try await client.execute(
                uri: "/v1/me/hermes-gateways/discord",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: putBody
            ) { response in
                #expect(response.status == .badRequest)
                let body = String(buffer: response.body)
                #expect(body.contains("missing_field"))
                #expect(body.contains("application_id"))
            }
        }
    }

    @Test
    func `PUT to unsupported gateway returns 404 with stable code`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let putBody = ByteBuffer(string: #"{"config":{"foo":"bar"}}"#)
            try await client.execute(
                // `signal` is a real Hermes platform we do not expose in the
                // catalog yet — a stable stand-in for an unsupported gateway id.
                uri: "/v1/me/hermes-gateways/signal",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: putBody
            ) { response in
                #expect(response.status == .notFound)
                let body = String(buffer: response.body)
                #expect(body.contains("unsupported_gateway"))
            }
        }
    }

    @Test
    func `DELETE clears stored config and returns 204`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)

            let putBody = ByteBuffer(string: #"{"config":{"bot_token":"abc"}}"#)
            _ = try await client.execute(
                uri: "/v1/me/hermes-gateways/telegram",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: putBody
            ) { $0.status }

            try await client.execute(
                uri: "/v1/me/hermes-gateways/telegram",
                method: .delete,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .noContent)
            }

            try await client.execute(
                uri: "/v1/me/hermes-gateways/telegram",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                let entry = try Self.decodeEntry(response.body)
                #expect(entry.status == .notConfigured)
                #expect(entry.hasConfig == false)
            }
        }
    }

    @Test
    func `tenant A's gateway invisible to tenant B`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tokenA = try await Self.register(client: client)
            let tokenB = try await Self.register(client: client)

            let putBody = ByteBuffer(string: #"{"config":{"bot_token":"TENANT-A-SECRET"}}"#)
            _ = try await client.execute(
                uri: "/v1/me/hermes-gateways/telegram",
                method: .put,
                headers: [.authorization: "Bearer \(tokenA)", .contentType: "application/json"],
                body: putBody
            ) { $0.status }

            try await client.execute(
                uri: "/v1/me/hermes-gateways/telegram",
                method: .get,
                headers: [.authorization: "Bearer \(tokenB)"]
            ) { response in
                #expect(response.status == .ok)
                let entry = try Self.decodeEntry(response.body)
                #expect(entry.status == .notConfigured)
                #expect(entry.hasConfig == false)
            }
        }
    }
}
