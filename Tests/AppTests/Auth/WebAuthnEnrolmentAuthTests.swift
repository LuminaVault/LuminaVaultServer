@testable import App
import Configuration
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// Passkey enrolment must prove account ownership.
///
/// Before this suite existed, `register/begin` and `register/finish` were
/// mounted on the unauthenticated auth group and resolved the account from a
/// body-supplied `username`. Any caller who knew a username could bind their
/// own authenticator to that account and then sign in as its owner. These
/// tests pin the two properties that close it: enrolment requires a bearer
/// token, and the token's user is the only account it can enrol for.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct WebAuthnEnrolmentAuthTests {
    private static let webAuthnReader = ConfigReader(providers: [
        InMemoryProvider(values: [
            "http.host": "127.0.0.1",
            "http.port": 0,
            "log.level": "warning",
            "postgres.host": cfg(TestPostgres.host),
            "postgres.port": cfg(TestPostgres.port),
            "postgres.database": cfg(TestDatabaseIsolation.resolvedDatabase),
            "postgres.user": cfg(TestPostgres.username),
            "postgres.password": cfg(TestPostgres.password),
            "fluent.autoMigrate": "true",
            "jwt.hmac.secret": "test-secret-do-not-use-in-prod-32chars",
            "jwt.kid": "test-kid",
            "hermes.gatewayKind": "logging",
            "vault.rootPath": "/tmp/luminavault-test",
            "webauthn.enabled": "true",
            "webauthn.relyingPartyId": "luminavault.test",
            "webauthn.relyingPartyName": "LuminaVault Test",
            "webauthn.relyingPartyOrigin": "https://luminavault.test",
        ]),
    ])

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("wae-\(suffix)@test.luminavault", "wae-\(suffix)")
    }

    private static func registerBody(email: String, username: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"CorrectHorseBatteryStaple1!"}
        """)
    }

    private static func beginBody(username: String) -> ByteBuffer {
        ByteBuffer(string: "{\"username\":\"\(username)\"}")
    }

    /// Registers a fresh account and returns its username + access token.
    private static func makeUser(
        _ client: some TestClientProtocol
    ) async throws -> (username: String, token: String) {
        let (email, username) = randomUser()
        let auth = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: email, username: username)
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: $0.body)) }
        return (username, auth.accessToken)
    }

    // MARK: - Enrolment requires a session

    @Test
    func `begin registration without a bearer is rejected`() async throws {
        let app = try await buildApplication(reader: Self.webAuthnReader)
        try await app.test(.router) { client in
            let victim = try await Self.makeUser(client)
            try await client.execute(
                uri: "/v1/auth/webauthn/register/begin",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.beginBody(username: victim.username)
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `deprecated register options alias also requires a bearer`() async throws {
        let app = try await buildApplication(reader: Self.webAuthnReader)
        try await app.test(.router) { client in
            let victim = try await Self.makeUser(client)
            try await client.execute(
                uri: "/v1/auth/webauthn/register/options",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.beginBody(username: victim.username)
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `finish registration without a bearer is rejected`() async throws {
        let app = try await buildApplication(reader: Self.webAuthnReader)
        try await app.test(.router) { client in
            let victim = try await Self.makeUser(client)
            // Body shape is irrelevant: the 401 comes from the middleware,
            // before the handler ever decodes it.
            try await client.execute(
                uri: "/v1/auth/webauthn/register/finish",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.beginBody(username: victim.username)
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    // MARK: - A session can only enrol for its own account

    @Test
    func `begin registration naming another user is forbidden`() async throws {
        let app = try await buildApplication(reader: Self.webAuthnReader)
        try await app.test(.router) { client in
            let victim = try await Self.makeUser(client)
            let attacker = try await Self.makeUser(client)

            try await client.execute(
                uri: "/v1/auth/webauthn/register/begin",
                method: .post,
                headers: [
                    .contentType: "application/json",
                    .authorization: "Bearer \(attacker.token)",
                ],
                body: Self.beginBody(username: victim.username)
            ) { response in
                #expect(response.status == .forbidden)
            }

            // And the victim still has no credentials to their name.
            try await client.execute(
                uri: "/v1/auth/webauthn/credentials",
                method: .get,
                headers: [.authorization: "Bearer \(victim.token)"]
            ) { response in
                #expect(response.status == .ok)
                let list = try testJSONDecoder().decode(
                    WebAuthnCredentialListResponse.self,
                    from: Data(buffer: response.body)
                )
                #expect(list.credentials.isEmpty)
            }
        }
    }

    @Test
    func `begin registration for the authenticated user issues a challenge`() async throws {
        let app = try await buildApplication(reader: Self.webAuthnReader)
        try await app.test(.router) { client in
            let user = try await Self.makeUser(client)
            try await client.execute(
                uri: "/v1/auth/webauthn/register/begin",
                method: .post,
                headers: [
                    .contentType: "application/json",
                    .authorization: "Bearer \(user.token)",
                ],
                body: Self.beginBody(username: user.username)
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("challenge"))
            }
        }
    }

    /// The client sends a username for wire compatibility, but the server
    /// takes the account from the token — so omitting it must still work.
    @Test
    func `begin registration without a username uses the token's account`() async throws {
        let app = try await buildApplication(reader: Self.webAuthnReader)
        try await app.test(.router) { client in
            let user = try await Self.makeUser(client)
            try await client.execute(
                uri: "/v1/auth/webauthn/register/begin",
                method: .post,
                headers: [
                    .contentType: "application/json",
                    .authorization: "Bearer \(user.token)",
                ],
                body: ByteBuffer(string: "{\"username\":\"\"}")
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains(user.username))
            }
        }
    }

    // MARK: - Sign-in stays open

    @Test
    func `authenticate begin remains reachable without a bearer`() async throws {
        let app = try await buildApplication(reader: Self.webAuthnReader)
        try await app.test(.router) { client in
            let user = try await Self.makeUser(client)
            try await client.execute(
                uri: "/v1/auth/webauthn/authenticate/begin",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.beginBody(username: user.username)
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("challenge"))
            }
        }
    }
}
