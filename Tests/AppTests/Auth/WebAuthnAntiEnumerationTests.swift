@testable import App
import Configuration
import FluentKit
import FluentPostgresDriver
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import Logging
import Testing

/// Verifies the sign-in /options endpoint doesn't leak user existence. Both
/// registered and unregistered usernames must receive a 200 with a
/// well-formed challenge — only /finish reveals whether the user exists.
///
/// Registration has no anti-enumeration property to test any more: enrolment
/// is authenticated and can only ever act on the caller's own account, so
/// there is no username to probe. Those cases moved to
/// `WebAuthnEnrolmentAuthTests`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct WebAuthnAntiEnumerationTests {
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

    @Test
    func `begin authentication returns 200 for unknown username`() async throws {
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
}
