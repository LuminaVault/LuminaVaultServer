@testable import App
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// E2E tests for QR-from-mobile web sign-in: `POST /v1/auth/pairing/start`,
/// `GET /v1/auth/pairing/{id}` and `POST /v1/auth/pairing/{id}/approve`.
///
/// The browser starts a pairing and polls it; the authenticated app approves
/// it; the browser's next poll picks up a token pair minted for the approving
/// user. The point of the happy-path test is the last step — that those tokens
/// authenticate as the *same* account the phone is signed into, which is what
/// makes web and iOS one account with one set of data.
///
/// Run with `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct PairingFlowTests {
    private static func decodeAuth(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeStart(_ buffer: ByteBuffer) throws -> PairingStartResponse {
        try testJSONDecoder().decode(PairingStartResponse.self, from: Data(buffer: buffer))
    }

    private static func decodePoll(_ buffer: ByteBuffer) throws -> PairingPollResponse {
        try testJSONDecoder().decode(PairingPollResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeMe(_ buffer: ByteBuffer) throws -> MeResponse {
        try testJSONDecoder().decode(MeResponse.self, from: Data(buffer: buffer))
    }

    private static func registerBody(email: String, username: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"CorrectHorseBatteryStaple1!"}
        """)
    }

    private static func approveBody(code: String) -> ByteBuffer {
        ByteBuffer(string: #"{"code":"\#(code)"}"#)
    }

    /// Registers a throwaway account and returns its access token — this stands
    /// in for the already-signed-in phone.
    private static func signedInPhone(_ client: some TestClientProtocol) async throws -> AuthResponse {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: "pair-\(suffix)@test.luminavault", username: "pair-\(suffix)")
        ) { response in
            #expect(response.status == .ok)
            return try decodeAuth(response.body)
        }
    }

    private static func startPairing(_ client: some TestClientProtocol) async throws -> PairingStartResponse {
        try await client.execute(
            uri: "/v1/auth/pairing/start",
            method: .post,
            headers: [.contentType: "application/json"]
        ) { response in
            #expect(response.status == .ok)
            return try decodeStart(response.body)
        }
    }

    @Test
    func `approved pairing hands the browser tokens for the approving account`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let phone = try await Self.signedInPhone(client)
            let start = try await Self.startPairing(client)

            #expect(!start.pairingId.isEmpty)
            #expect(start.code.count == 6)
            #expect(start.expiresAt > Int(Date().timeIntervalSince1970 * 1000))

            // Before approval the browser just keeps polling.
            try await client.execute(uri: "/v1/auth/pairing/\(start.pairingId)", method: .get) { response in
                #expect(response.status == .ok)
                let poll = try Self.decodePoll(response.body)
                #expect(poll.approved == false)
                #expect(poll.accessToken == nil)
            }

            try await client.execute(
                uri: "/v1/auth/pairing/\(start.pairingId)/approve",
                method: .post,
                headers: [.contentType: "application/json", .authorization: "Bearer \(phone.accessToken)"],
                body: Self.approveBody(code: start.code)
            ) { response in
                #expect(response.status == .noContent)
            }

            let poll = try await client.execute(
                uri: "/v1/auth/pairing/\(start.pairingId)",
                method: .get
            ) { response -> PairingPollResponse in
                #expect(response.status == .ok)
                return try Self.decodePoll(response.body)
            }

            #expect(poll.approved)
            #expect(poll.userId == phone.userId)
            let browserToken = try #require(poll.accessToken)
            #expect(!browserToken.isEmpty)
            #expect(poll.refreshToken?.isEmpty == false)

            // The whole point: the browser's token is the phone's account.
            try await client.execute(
                uri: "/v1/auth/me",
                method: .get,
                headers: [.authorization: "Bearer \(browserToken)"]
            ) { response in
                #expect(response.status == .ok)
                let me = try Self.decodeMe(response.body)
                #expect(me.userId == phone.userId)
            }
        }
    }

    @Test
    func `wrong code is rejected and leaves the pairing pending`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let phone = try await Self.signedInPhone(client)
            let start = try await Self.startPairing(client)
            let wrongCode = start.code == "000000" ? "111111" : "000000"

            try await client.execute(
                uri: "/v1/auth/pairing/\(start.pairingId)/approve",
                method: .post,
                headers: [.contentType: "application/json", .authorization: "Bearer \(phone.accessToken)"],
                body: Self.approveBody(code: wrongCode)
            ) { response in
                #expect(response.status == .unauthorized)
            }

            try await client.execute(uri: "/v1/auth/pairing/\(start.pairingId)", method: .get) { response in
                #expect(response.status == .ok)
                // Bind, then assert. `#expect` expands its argument into a
                // position this closure will not propagate a throw from, so
                // `#expect(try ...)` here fails to build — matching how the
                // other polls in this file are already written.
                let poll = try Self.decodePoll(response.body)
                #expect(poll.approved == false)
            }
        }
    }

    @Test
    func `a pairing can only be approved once`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let phone = try await Self.signedInPhone(client)
            let start = try await Self.startPairing(client)
            let headers: HTTPFields = [
                .contentType: "application/json",
                .authorization: "Bearer \(phone.accessToken)",
            ]

            try await client.execute(
                uri: "/v1/auth/pairing/\(start.pairingId)/approve",
                method: .post,
                headers: headers,
                body: Self.approveBody(code: start.code)
            ) { response in
                #expect(response.status == .noContent)
            }

            try await client.execute(
                uri: "/v1/auth/pairing/\(start.pairingId)/approve",
                method: .post,
                headers: headers,
                body: Self.approveBody(code: start.code)
            ) { response in
                #expect(response.status == .conflict)
            }
        }
    }

    @Test
    func `unknown pairing id is a 404 on both poll and approve`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let phone = try await Self.signedInPhone(client)
            let unknown = UUID().uuidString

            try await client.execute(uri: "/v1/auth/pairing/\(unknown)", method: .get) { response in
                #expect(response.status == .notFound)
            }

            try await client.execute(
                uri: "/v1/auth/pairing/\(unknown)/approve",
                method: .post,
                headers: [.contentType: "application/json", .authorization: "Bearer \(phone.accessToken)"],
                body: Self.approveBody(code: "123456")
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func `approve requires a bearer token`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let start = try await Self.startPairing(client)

            try await client.execute(
                uri: "/v1/auth/pairing/\(start.pairingId)/approve",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.approveBody(code: start.code)
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }
}
