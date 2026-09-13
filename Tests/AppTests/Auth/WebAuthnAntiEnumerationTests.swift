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
    private static let webAuthnReader = dbTestReader(overriding: [
        "webauthn.enabled": cfg("true"),
        "webauthn.relyingPartyId": cfg("luminavault.test"),
        "webauthn.relyingPartyName": cfg("LuminaVault Test"),
        "webauthn.relyingPartyOrigin": cfg("https://luminavault.test"),
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
