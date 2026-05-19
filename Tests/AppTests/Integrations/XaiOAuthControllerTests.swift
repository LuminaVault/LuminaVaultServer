@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import struct LuminaVaultShared.AuthResponse
import Testing

/// HER-240a — `/v1/integrations/xai` HTTP route E2E. Runs against the real
/// router + Postgres + `LiveXaiOAuthBackend`. Because the live backend's
/// `requestAuthorizeURL` and `submitCallback` are not yet implemented (see
/// `XaiOAuthBackend.swift`), we only assert the contract surface:
///
///   * `GET    /v1/integrations/xai`          200, default state for a new user
///   * `POST   /v1/integrations/xai/start`    501 — backend not enabled
///   * `POST   /v1/integrations/xai/complete` 404 — unknown session
///   * `DELETE /v1/integrations/xai`          200, demotes tier
///
/// When HER-240b lands a wired backend, this file gains a `start →
/// complete → premium` happy path.
@Suite(.serialized)
struct XaiOAuthControllerTests {
    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("xai-\(suffix)@test.luminavault", "xai-\(suffix)")
    }

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func decodeAuth(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func register(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        let body = registerBody(email: email, username: username, password: "CorrectHorseBatteryStaple1!")
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body,
        ) { try decodeAuth($0.body).accessToken }
    }

    @Test
    func `GET status returns disconnected default for fresh user`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/integrations/xai",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let body = try testJSONDecoder().decode(XaiStatusResponse.self, from: Data(buffer: response.body))
                #expect(body.connected == false)
                #expect(body.xaiConnectedAt == nil)
                // The freshly-registered user starts on the trial tier.
                #expect(body.tier == "trial")
            }
        }
    }

    @Test
    func `GET status without bearer token returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/integrations/xai",
                method: .get,
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `POST complete with unknown session returns 404`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let body = ByteBuffer(string: #"{"sessionID":"ghost","callbackURL":"http://127.0.0.1:56121/callback?code=x"}"#)
            try await client.execute(
                uri: "/v1/integrations/xai/complete",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body,
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func `POST complete with empty body returns 400`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let body = ByteBuffer(string: #"{"sessionID":"","callbackURL":""}"#)
            try await client.execute(
                uri: "/v1/integrations/xai/complete",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body,
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }
}
