@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import JWTKit
import Logging
import LuminaVaultShared
import SQLKit
import Testing

/// HER-92 end-to-end tests for `DELETE /v1/account`.
/// Run with `docker compose up -d postgres`.
///
/// Coverage:
///   * password gate (correct / incorrect / missing)
///   * fresh-JWT gate
///   * cascade verification across every FK-owned child table
///   * tenant isolation (token for user A cannot wipe user B)
@Suite(.serialized)
struct AccountDeletionTests {
    private static let testPassword = "CorrectHorseBatteryStaple1!"

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func decodeAuthResponse(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("acct-\(suffix)@test.luminavault", "acct-\(suffix)")
    }

    /// Registers a user, returns the response (includes userId + accessToken).
    private static func register(client: some TestClientProtocol) async throws -> AuthResponse {
        let (email, username) = randomUser()
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: email, username: username, password: testPassword),
        ) { try decodeAuthResponse($0.body) }
    }

    @Test
    func `delete with correct password returns 204`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let body = ByteBuffer(string: #"{"password":"\#(Self.testPassword)"}"#)
            try await client.execute(
                uri: "/v1/account",
                method: .delete,
                headers: [.authorization: "Bearer \(auth.accessToken)", .contentType: "application/json"],
                body: body,
            ) { response in
                #expect(response.status == .noContent)
            }
        }
    }

    @Test
    func `delete with wrong password returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let body = ByteBuffer(string: #"{"password":"definitely-wrong"}"#)
            try await client.execute(
                uri: "/v1/account",
                method: .delete,
                headers: [.authorization: "Bearer \(auth.accessToken)", .contentType: "application/json"],
                body: body,
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `delete with fresh JWT and no password succeeds`() async throws {
        // The JWT minted by /register has `iat ≈ now`, well inside the 5-minute
        // fresh-auth window — so omitting `password` is acceptable.
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/account",
                method: .delete,
                headers: [.authorization: "Bearer \(auth.accessToken)", .contentType: "application/json"],
                body: ByteBuffer(string: "{}"),
            ) { response in
                #expect(response.status == .noContent)
            }
        }
    }

    @Test
    func `delete with stale JWT and no password returns 401`() async throws {
        // Mint a token that's structurally valid but whose `iat` is 10 minutes
        // old — outside the 5-min fresh-auth window. Password is omitted, so
        // the only re-auth path is fresh-JWT, which fails.
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)

            let keys = JWTKeyCollection()
            let kid = JWKIdentifier(string: "test-kid")
            await keys.add(
                hmac: HMACKey(stringLiteral: "test-secret-do-not-use-in-prod-32chars"),
                digestAlgorithm: .sha256, kid: kid,
            )
            let now = Date()
            let stale = SessionToken(
                userID: auth.userId,
                expiration: now.addingTimeInterval(3600),
                issuedAt: now.addingTimeInterval(-600),
            )
            let signed = try await keys.sign(stale, kid: kid)

            try await client.execute(
                uri: "/v1/account",
                method: .delete,
                headers: [.authorization: "Bearer \(signed)", .contentType: "application/json"],
                body: ByteBuffer(string: "{}"),
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `unauthenticated returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/account", method: .delete) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `delete cascades across all child tables`() async throws {
        // Drives a single user through the full life cycle: register, push
        // device token, upsert a memory, set onboarding flags, delete.
        // Verifies the `users` row AND every FK-owned table is empty for
        // the deleted tenant.
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let auth = try await Self.register(client: client)
            let token = auth.accessToken
            let tenantID = auth.userId

            // 1) Device token row
            let deviceBody = ByteBuffer(string: #"{"token":"apns-\#(UUID().uuidString)","platform":"ios"}"#)
            try await client.execute(
                uri: "/v1/devices",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: deviceBody,
            ) { #expect($0.status == .ok || $0.status == .created) }

            // 2) Memory row
            let memBody = ByteBuffer(string: #"{"content":"will be wiped"}"#)
            try await client.execute(
                uri: "/v1/memory/upsert",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: memBody,
            ) { #expect($0.status == .ok || $0.status == .created) }

            // 3) Onboarding row (lazy-created on first GET)
            try await client.execute(
                uri: "/v1/onboarding",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { #expect($0.status == .ok) }

            // 4) Delete
            let delBody = ByteBuffer(string: #"{"password":"\#(Self.testPassword)"}"#)
            try await client.execute(
                uri: "/v1/account",
                method: .delete,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: delBody,
            ) { #expect($0.status == .noContent) }

            // 5) Verify cascade in DB directly. We can't reach the app's Fluent
            // handle from the test, so spin up an ephemeral one against the
            // same test database.
            let fluent = try await Self.openTestFluent()
            defer { Task { try? await fluent.shutdown() } }

            try await Self.expectEmpty(table: "users", tenantColumn: "id", tenantID: tenantID, fluent: fluent)
            try await Self.expectEmpty(table: "refresh_tokens", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
            try await Self.expectEmpty(table: "password_reset_tokens", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
            try await Self.expectEmpty(table: "mfa_challenges", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
            try await Self.expectEmpty(table: "oauth_identities", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
            try await Self.expectEmpty(table: "memories", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
            try await Self.expectEmpty(table: "hermes_profiles", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
            try await Self.expectEmpty(table: "device_tokens", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
            try await Self.expectEmpty(table: "webauthn_credentials", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
            try await Self.expectEmpty(table: "spaces", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
            try await Self.expectEmpty(table: "vault_files", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
            try await Self.expectEmpty(table: "health_events", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
            try await Self.expectEmpty(table: "email_verification_tokens", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
            try await Self.expectEmpty(table: "onboarding_state", tenantColumn: "tenant_id", tenantID: tenantID, fluent: fluent)
        }
    }

    @Test
    func `tenant isolation cannot delete another user`() async throws {
        // Mallory's token must not authorize wiping Alice. The DELETE acts
        // on the authenticated identity, not a path parameter, so an attacker
        // can't even target Alice's userID — but verify Alice survives anyway.
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let alice = try await Self.register(client: client)
            let mallory = try await Self.register(client: client)

            let body = ByteBuffer(string: #"{"password":"\#(Self.testPassword)"}"#)
            try await client.execute(
                uri: "/v1/account",
                method: .delete,
                headers: [.authorization: "Bearer \(mallory.accessToken)", .contentType: "application/json"],
                body: body,
            ) { #expect($0.status == .noContent) }

            let fluent = try await Self.openTestFluent()
            defer { Task { try? await fluent.shutdown() } }

            let aliceRow = try await User.find(alice.userId, on: fluent.db())
            #expect(aliceRow != nil, "Alice's row must survive Mallory's account deletion")
        }
    }

    // MARK: - Helpers

    private static func openTestFluent() async throws -> Fluent {
        let fluent = Fluent(logger: Logger(label: "test.account.delete"))
        fluent.databases.use(
            .postgres(configuration: TestPostgres.configuration()),
            as: .psql,
        )
        return fluent
    }

    private static func expectEmpty(
        table: String,
        tenantColumn: String,
        tenantID: UUID,
        fluent: Fluent,
    ) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else {
            Issue.record("SQL driver unavailable")
            return
        }
        struct CountRow: Decodable { let n: Int }
        // Whitelisted identifiers (test code, no external input) so we can
        // splice them into the SQL string without parameterisation.
        let rows = try await sql.raw("""
        SELECT COUNT(*)::int AS n FROM \(unsafeRaw: table) WHERE \(unsafeRaw: tenantColumn) = \(bind: tenantID)
        """).all(decoding: CountRow.self)
        #expect(rows.first?.n == 0, "expected \(table) to be empty after cascade, got \(rows.first?.n ?? -1)")
    }
}
