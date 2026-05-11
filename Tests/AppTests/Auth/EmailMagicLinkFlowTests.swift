@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import Logging
import Testing

/// HER-138 E2E tests for `POST /v1/auth/email/start` + `/email/verify`.
///
/// `dbTestReader` pins `magic.fixedOtp = "313131"` so verify is
/// deterministic. `LoggingEmailOTPSender` is used by default so no real
/// email is sent. Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct EmailMagicLinkFlowTests {
    private static let fixedOTP = "313131"

    private static func randomEmail() -> String {
        "magic-\(UUID().uuidString.prefix(8).lowercased())@example.test"
    }

    /// Server emits dates as ISO-8601 strings (Hummingbird default response
    /// encoder for this surface), but `JSONDecoder` defaults to numeric
    /// (`.deferredToDate`). Pin iso8601 explicitly so the test isn't coupled
    /// to either side's default. PhoneAuthFlowTests happens to dodge this
    /// because its start-response decoder is only consulted for fields the
    /// happy-path doesn't actually inspect; reproducing the asymmetry here
    /// would be cute, not useful.
    private static func jsonDecoder() -> JSONDecoder {
        let d = testJSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func decodeStart(_ buf: ByteBuffer) throws -> EmailMagicStartResponse {
        try jsonDecoder().decode(EmailMagicStartResponse.self, from: Data(buffer: buf))
    }

    private static func decodeAuth(_ buf: ByteBuffer) throws -> AuthResponse {
        try jsonDecoder().decode(AuthResponse.self, from: Data(buffer: buf))
    }

    private static func startBody(email: String) -> ByteBuffer {
        ByteBuffer(string: #"{"email":"\#(email)"}"#)
    }

    /// Bodies are tiny so build them inline rather than relying on
    /// JSONEncoder + string interpolation gymnastics.
    private static func verifyJSON(email: String, code: String) -> ByteBuffer {
        ByteBuffer(string: #"{"email":"\#(email)","code":"\#(code)"}"#)
    }

    @Test
    func `start then verify creates user with email magic link identity`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let email = Self.randomEmail()

            try await client.execute(
                uri: "/v1/auth/email/start",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.startBody(email: email),
            ) { response in
                #expect(response.status == .ok)
                let start = try Self.decodeStart(response.body)
                #expect(start.expiresAt > Date())
            }

            let auth = try await client.execute(
                uri: "/v1/auth/email/verify",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.verifyJSON(email: email, code: Self.fixedOTP),
            ) { response -> AuthResponse in
                #expect(response.status == .ok)
                return try Self.decodeAuth(response.body)
            }

            #expect(!auth.accessToken.isEmpty)
            #expect(!auth.refreshToken.isEmpty)

            // Verify the OAuthIdentity row landed with provider="email_magic_link".
            let fluent = try await Self.openFluent()
            defer { Task { try? await fluent.shutdown() } }
            let identity = try await OAuthIdentity.query(on: fluent.db())
                .filter(\.$tenantID == auth.userId)
                .filter(\.$provider == "email_magic_link")
                .first()
            #expect(identity != nil, "expected OAuthIdentity(provider: email_magic_link) for tenant \(auth.userId)")
            #expect(identity?.providerUserID == email)
        }
    }

    @Test
    func `verify with bad code returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let email = Self.randomEmail()

            try await client.execute(
                uri: "/v1/auth/email/start",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.startBody(email: email),
            ) { #expect($0.status == .ok) }

            try await client.execute(
                uri: "/v1/auth/email/verify",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.verifyJSON(email: email, code: "000000"),
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `verify without start returns 401`() async throws {
        // No prior /email/start → no challenge in store → consume returns nil →
        // controller throws AuthError.otpInvalid (401). 410 Gone is reserved
        // for the expired-lifetime case (not covered by current controller
        // which uses the legacy optional-returning consume API).
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/auth/email/verify",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.verifyJSON(email: Self.randomEmail(), code: Self.fixedOTP),
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `start rejects invalid email`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/auth/email/start",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.startBody(email: "no-at-sign"),
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test
    func `second start issues fresh challenge and burns old code`() async throws {
        // Mirrors PhoneAuthFlowTests' reissue test: a re-issued challenge
        // wins (latest send), then burns on the first successful verify,
        // and a replay of that same code yields 401.
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let email = Self.randomEmail()

            try await client.execute(
                uri: "/v1/auth/email/start",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.startBody(email: email),
            ) { #expect($0.status == .ok) }

            try await client.execute(
                uri: "/v1/auth/email/start",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.startBody(email: email),
            ) { #expect($0.status == .ok) }

            try await client.execute(
                uri: "/v1/auth/email/verify",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.verifyJSON(email: email, code: Self.fixedOTP),
            ) { #expect($0.status == .ok) }

            try await client.execute(
                uri: "/v1/auth/email/verify",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.verifyJSON(email: email, code: Self.fixedOTP),
            ) { #expect($0.status == .unauthorized) }
        }
    }

    // MARK: - Helpers

    private static func openFluent() async throws -> Fluent {
        let fluent = Fluent(logger: Logger(label: "test.magic.fluent"))
        fluent.databases.use(
            .postgres(configuration: TestPostgres.configuration()),
            as: .psql,
        )
        return fluent
    }
}
