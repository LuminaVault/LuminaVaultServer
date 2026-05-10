import Configuration
import FluentKit
import FluentPostgresDriver
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import Logging
import Testing

@testable import App

/// Verifies the /options endpoints don't leak user existence. Both
/// registered and unregistered usernames must receive a 200 with a
/// well-formed challenge — only /finish reveals whether the user exists.
@Suite(.serialized)
struct WebAuthnAntiEnumerationTests {

    private static let webAuthnReader = ConfigReader(providers: [
        InMemoryProvider(values: [
            "http.host": "127.0.0.1",
            "http.port": 0,
            "log.level": "warning",
            "postgres.host": "127.0.0.1",
            "postgres.port": 5433,
            "postgres.database": "hermes_db",
            "postgres.user": "hermes",
            "postgres.password": "luminavault",
            "fluent.autoMigrate": "true",
            "jwt.hmac.secret": "test-secret-do-not-use-in-prod-32chars",
            "jwt.kid": "test-kid",
            "hermes.gatewayKind": "logging",
            "vault.rootPath": "/tmp/luminavault-test",
            "webauthn.enabled": "true",
            "webauthn.relyingPartyId": "luminavault.test",
            "webauthn.relyingPartyName": "LuminaVault Test",
            "webauthn.relyingPartyOrigin": "https://luminavault.test"
        ])
    ])

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    @Test
    func beginRegistrationReturns200ForUnknownUsername() async throws {
        let app = try await buildApplication(reader: Self.webAuthnReader)
        try await app.test(.router) { client in
            // Username never registered.
            let unknown = "ghost-\(UUID().uuidString.prefix(6).lowercased())"
            try await client.execute(
                uri: "/v1/auth/webauthn/register/options",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: "{\"username\":\"\(unknown)\"}")
            ) { response in
                #expect(response.status == .ok)
                // Body should contain a challenge — proves we issued real-looking options
                let raw = String(buffer: response.body)
                #expect(raw.contains("challenge"))
            }
        }
    }

    @Test
    func beginAuthenticationReturns200ForUnknownUsername() async throws {
        let app = try await buildApplication(reader: Self.webAuthnReader)
        try await app.test(.router) { client in
            let unknown = "ghost-\(UUID().uuidString.prefix(6).lowercased())"
            try await client.execute(
                uri: "/v1/auth/webauthn/authenticate/options",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: "{\"username\":\"\(unknown)\"}")
            ) { response in
                #expect(response.status == .ok)
                let raw = String(buffer: response.body)
                #expect(raw.contains("challenge"))
            }
        }
    }

    @Test
    func beginRegistrationReturns200ForKnownUsername() async throws {
        let app = try await buildApplication(reader: Self.webAuthnReader)
        try await app.test(.router) { client in
            let username = "wax\(UUID().uuidString.prefix(6).lowercased())"
            // Register a real user first.
            try await client.execute(
                uri: "/v1/auth/register",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.registerBody(
                    email: "wax-\(UUID().uuidString.prefix(6).lowercased())@test.luminavault",
                    username: username,
                    password: "CorrectHorseBatteryStaple1!"
                )
            ) { _ in }

            try await client.execute(
                uri: "/v1/auth/webauthn/register/options",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: "{\"username\":\"\(username)\"}")
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }
}
