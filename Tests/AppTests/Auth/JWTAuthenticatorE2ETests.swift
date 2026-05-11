@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import JWTKit
import Testing

/// Drives the full middleware chain through `app.test(.router)` so a real
/// JWT travels in `Authorization: Bearer ...` and JWTAuthenticator hydrates
/// `AppRequestContext.identity`. Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct JWTAuthenticatorE2ETests {
    private static let jwtSecret = "test-secret-do-not-use-in-prod-32chars"
    private static let jwtKid = "test-kid"

    /// Sign an arbitrary `SessionToken` payload with the same key the test
    /// app uses, for cases where we want to mint deliberately-bad tokens.
    private static func sign(_ token: SessionToken) async throws -> String {
        let keys = JWTKeyCollection()
        let kid = JWKIdentifier(string: jwtKid)
        await keys.add(hmac: HMACKey(stringLiteral: jwtSecret), digestAlgorithm: .sha256, kid: kid)
        return try await keys.sign(token, kid: kid)
    }

    private static func decodeAuthResponse(_ buffer: ByteBuffer) throws -> AuthResponse {
        let data = Data(buffer: buffer)
        return try testJSONDecoder().decode(AuthResponse.self, from: data)
    }

    private static func decodeMeResponse(_ buffer: ByteBuffer) throws -> MeResponse {
        let data = Data(buffer: buffer)
        return try testJSONDecoder().decode(MeResponse.self, from: data)
    }

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("e2e-\(suffix)@test.luminavault", "e2e-\(suffix)")
    }

    @Test
    func `valid bearer authorizes protected route`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (email, username) = Self.randomUser()
            let registerResp = try await client.execute(
                uri: "/v1/auth/register",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.registerBody(email: email, username: username, password: "CorrectHorseBatteryStaple1!"),
            ) { try Self.decodeAuthResponse($0.body) }

            #expect(!registerResp.accessToken.isEmpty)

            try await client.execute(
                uri: "/v1/auth/me",
                method: .get,
                headers: [.authorization: "Bearer \(registerResp.accessToken)"],
            ) { response in
                #expect(response.status == .ok)
                let me = try Self.decodeMeResponse(response.body)
                #expect(me.email == email.lowercased())
                #expect(me.username == username)
                #expect(me.userId == registerResp.userId)
            }
        }
    }

    @Test
    func `missing authorization header returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/auth/me", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `malformed authorization header returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            // No "Bearer " prefix
            try await client.execute(
                uri: "/v1/auth/me",
                method: .get,
                headers: [.authorization: "garbage"],
            ) { response in
                #expect(response.status == .unauthorized)
            }
            // Bearer but token is junk
            try await client.execute(
                uri: "/v1/auth/me",
                method: .get,
                headers: [.authorization: "Bearer not-a-jwt"],
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `expired token returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let expired = SessionToken(
                userID: UUID(),
                expiration: Date().addingTimeInterval(-3600),
            )
            let signed = try await Self.sign(expired)
            try await client.execute(
                uri: "/v1/auth/me",
                method: .get,
                headers: [.authorization: "Bearer \(signed)"],
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `wrong signature returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            // Sign with a DIFFERENT secret; the app's verifier must reject it.
            let otherKeys = JWTKeyCollection()
            let kid = JWKIdentifier(string: Self.jwtKid)
            await otherKeys.add(
                hmac: HMACKey(stringLiteral: "different-secret-different-different-x"),
                digestAlgorithm: .sha256, kid: kid,
            )
            let token = SessionToken(userID: UUID(), expiration: Date().addingTimeInterval(3600))
            let signed = try await otherKeys.sign(token, kid: kid)
            try await client.execute(
                uri: "/v1/auth/me",
                method: .get,
                headers: [.authorization: "Bearer \(signed)"],
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `token for unknown user returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            // Validly signed but the user UUID was never persisted.
            let orphan = SessionToken(
                userID: UUID(),
                expiration: Date().addingTimeInterval(3600),
            )
            let signed = try await Self.sign(orphan)
            try await client.execute(
                uri: "/v1/auth/me",
                method: .get,
                headers: [.authorization: "Bearer \(signed)"],
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `issued token carries hpid claim`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (email, username) = Self.randomUser()
            let registerResp = try await client.execute(
                uri: "/v1/auth/register",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.registerBody(email: email, username: username, password: "CorrectHorseBatteryStaple1!"),
            ) { try Self.decodeAuthResponse($0.body) }

            let keys = JWTKeyCollection()
            let kid = JWKIdentifier(string: Self.jwtKid)
            await keys.add(hmac: HMACKey(stringLiteral: Self.jwtSecret), digestAlgorithm: .sha256, kid: kid)
            let decoded = try await keys.verify(registerResp.accessToken, as: SessionToken.self)
            #expect(decoded.userID == registerResp.userId)
            #expect(decoded.hpid == "hermes-\(username)")
        }
    }
}
