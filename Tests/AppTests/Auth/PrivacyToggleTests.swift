@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// HER-176 E2E tests for `PUT /v1/me/privacy` and the privacy field in
/// `GET /v1/me`. Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct PrivacyToggleTests {
    private static func decodeAuth(_ buf: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buf))
    }

    private static func decodeMe(_ buf: ByteBuffer) throws -> MeResponse {
        try testJSONDecoder().decode(MeResponse.self, from: Data(buffer: buf))
    }

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: #"{"email":"\#(email)","username":"\#(username)","password":"\#(password)"}"#)
    }

    private static func registerAndAuth(client: some TestClientProtocol) async throws -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let email = "priv-\(suffix)@test.luminavault"
        let username = "priv\(suffix)"
        let resp = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: email, username: username, password: "CorrectHorseBatteryStaple1!"),
        ) { try decodeAuth($0.body) }
        return resp.accessToken
    }

    @Test
    func `new user defaults to privacy off`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            try await client.execute(
                uri: "/v1/auth/me",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let me = try Self.decodeMe(response.body)
                #expect(me.privacyNoCNOrigin == false)
            }
        }
    }

    @Test
    func `put me privacy flips toggle and persists`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)

            // Flip ON
            try await client.execute(
                uri: "/v1/auth/me/privacy",
                method: .put,
                headers: [
                    .contentType: "application/json",
                    .authorization: "Bearer \(token)",
                ],
                body: ByteBuffer(string: #"{"privacyNoCNOrigin":true}"#),
            ) { response in
                #expect(response.status == .ok)
                let me = try Self.decodeMe(response.body)
                #expect(me.privacyNoCNOrigin == true)
            }

            // GET /me reflects new state
            try await client.execute(
                uri: "/v1/auth/me",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                let me = try Self.decodeMe(response.body)
                #expect(me.privacyNoCNOrigin == true)
            }

            // Flip OFF
            try await client.execute(
                uri: "/v1/auth/me/privacy",
                method: .put,
                headers: [
                    .contentType: "application/json",
                    .authorization: "Bearer \(token)",
                ],
                body: ByteBuffer(string: #"{"privacyNoCNOrigin":false}"#),
            ) { response in
                let me = try Self.decodeMe(response.body)
                #expect(me.privacyNoCNOrigin == false)
            }
        }
    }

    @Test
    func `put me privacy requires bearer`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/auth/me/privacy",
                method: .put,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"privacyNoCNOrigin":true}"#),
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }
}
