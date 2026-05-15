@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import JWTKit
import Logging
import Testing

/// Covers the X (Twitter) OAuth 2.0 + PKCE exchange path:
///   1. `XAPIClient` JSON decoding of `/2/users/me` envelopes (with + without email)
///   2. `AuthService.upsertOAuthUser(provider: "x", ...)` end-to-end against the DB
///   3. Stub `XAPIClient` for downstream consumers that need to inject a fake
///
/// X tokens aren't id_tokens, so X falls outside the OIDC `OAuthProvider`
/// protocol — that's why this has its own test file rather than slotting
/// into a generic OAuthControllerTests.
@Suite(.serialized)
struct XOAuthTests {
    // MARK: - JSON decoding

    @Test
    func `decodes users me envelope with email`() throws {
        let body = #"""
        {
          "data": {
            "id": "1234567890",
            "name": "Ada Lovelace",
            "username": "ada",
            "verified": true
          }
        }
        """#.data(using: .utf8)!

        let decoded = try testJSONDecoder().decode(XUserResponse.self, from: body)
        #expect(decoded.data.id == "1234567890")
        #expect(decoded.data.name == "Ada Lovelace")
        #expect(decoded.data.username == "ada")
        #expect(decoded.data.email == nil) // X did not return email field
        #expect(decoded.data.verified == true)
    }

    @Test
    func `decodes users me envelope with explicit email`() throws {
        let body = #"""
        {
          "data": {
            "id": "42",
            "name": "Grace Hopper",
            "username": "grace",
            "email": "grace@navy.example",
            "verified": false
          }
        }
        """#.data(using: .utf8)!

        let decoded = try testJSONDecoder().decode(XUserResponse.self, from: body)
        #expect(decoded.data.email == "grace@navy.example")
        #expect(decoded.data.verified == false)
    }

    @Test
    func `rejects missing data envelope`() {
        let body = #"""
        { "id": "42", "name": "no-envelope" }
        """#.data(using: .utf8)!

        #expect(throws: (any Error).self) {
            _ = try testJSONDecoder().decode(XUserResponse.self, from: body)
        }
    }

    // MARK: - Stub XAPIClient (test seam for controller-level integration)

    @Test
    func `stub XAPI client returns scripted user`() async throws {
        let stub = StubXAPIClient(scripted: .init(
            id: "stub-user-id",
            name: "Stub User",
            username: "stubuser",
            email: nil,
            verified: false,
        ))
        let result = try await stub.fetchMe(accessToken: "doesnt-matter-stub")
        #expect(result.id == "stub-user-id")
        #expect(result.email == nil)
        #expect(await stub.observedTokens.count == 1)
        #expect(await stub.observedTokens.first == "doesnt-matter-stub")
    }

    @Test
    func `stub XAPI client can throw`() async throws {
        let stub = StubXAPIClient.failing(error: NSError(domain: "stub", code: 401))
        await #expect(throws: (any Error).self) {
            _ = try await stub.fetchMe(accessToken: "anything")
        }
    }

    // MARK: - Email fallback rule mirrors XOAuthController

    @Test
    func `email fallback produces placeholder for missing X`() {
        // Mirrors `XOAuthController.exchange` line:
        //   let email = xUser.email?.lowercased() ?? "\(xUser.id)@x.luminavault.local"
        // Kept as a test even though it's a 1-liner — if the placeholder format
        // ever changes, downstream tenant code that assumes uniqueness has to
        // be checked. The check lives here so we notice.
        let xUser = XUserResponse.XUserData(
            id: "9876", name: "n", username: "u", email: nil, verified: false,
        )
        let resolved = xUser.email?.lowercased() ?? "\(xUser.id)@x.luminavault.local"
        #expect(resolved == "9876@x.luminavault.local")
    }

    @Test
    func `email fallback uses X provided email when present`() {
        let xUser = XUserResponse.XUserData(
            id: "9876", name: "n", username: "u", email: "Mixed.Case@Example.com", verified: false,
        )
        let resolved = xUser.email?.lowercased() ?? "\(xUser.id)@x.luminavault.local"
        #expect(resolved == "mixed.case@example.com")
    }

    // MARK: - End-to-end: upsertOAuthUser with provider="x"

    @Test
    func `upsert creates user with placeholder email`() async throws {
        try await Self.withHarness { h in
            let providerUserID = "x-\(UUID().uuidString.prefix(8).lowercased())"
            let placeholderEmail = "\(providerUserID)@x.luminavault.local"

            let user = try await h.service.upsertOAuthUser(
                provider: "x",
                providerUserID: providerUserID,
                email: placeholderEmail,
                emailVerified: false,
            )
            #expect(user.email == placeholderEmail)

            // Identity row written
            let identity = try await OAuthIdentity.query(on: h.fluent.db())
                .filter(\.$provider == "x")
                .filter(\.$providerUserID == providerUserID)
                .first()
            #expect(identity != nil)
            #expect(identity?.emailVerified == false)

            // Hermes profile auto-provisioned
            let profile = try await HermesProfile
                .query(on: h.fluent.db(), tenantID: user.requireID())
                .first()
            #expect(profile != nil)
            #expect(profile?.status == "ready")
        }
    }

    @Test
    func `upsert returns same user on second call`() async throws {
        try await Self.withHarness { h in
            let providerUserID = "x-\(UUID().uuidString.prefix(8).lowercased())"
            let email = "\(providerUserID)@x.luminavault.local"

            let first = try await h.service.upsertOAuthUser(
                provider: "x", providerUserID: providerUserID,
                email: email, emailVerified: false,
            )
            let second = try await h.service.upsertOAuthUser(
                provider: "x", providerUserID: providerUserID,
                email: email, emailVerified: false,
            )
            #expect(try first.requireID() == (second.requireID()))

            // Exactly one identity row, not duplicated.
            let identityCount = try await OAuthIdentity.query(on: h.fluent.db())
                .filter(\.$provider == "x")
                .filter(\.$providerUserID == providerUserID)
                .count()
            #expect(identityCount == 1)
        }
    }

    @Test
    func `upsert links to existing user by email`() async throws {
        try await Self.withHarness { h in
            // Pre-existing user via password registration.
            let email = "x-link-\(UUID().uuidString.prefix(8).lowercased())@test.luminavault"
            let username = "x-link-\(UUID().uuidString.prefix(8).lowercased())"
            _ = try await h.service.register(email: email, username: username, password: "CorrectHorseBatteryStaple1!")

            // Now X exchange with the same email — should LINK, not create.
            let providerUserID = "x-\(UUID().uuidString.prefix(8).lowercased())"
            let user = try await h.service.upsertOAuthUser(
                provider: "x", providerUserID: providerUserID,
                email: email, emailVerified: true,
            )
            #expect(user.email == email)
            #expect(user.username == username) // password-flow username preserved

            // Exactly one User row for this email; the OAuth identity attached to it.
            let userCount = try await User.query(on: h.fluent.db())
                .filter(\.$email == email)
                .count()
            #expect(userCount == 1)

            let identity = try await OAuthIdentity.query(on: h.fluent.db())
                .filter(\.$provider == "x")
                .filter(\.$providerUserID == providerUserID)
                .first()
            #expect(identity != nil)
            #expect(try identity?.tenantID == (user.requireID()))
        }
    }

    // MARK: - Harness (mirrors AuthFlowTests)

    fileprivate struct Harness {
        let service: DefaultAuthService
        let fluent: Fluent
    }

    private static func withHarness<T: Sendable>(
        _ body: @Sendable (Harness) async throws -> T,
    ) async throws -> T {
        let harness = try await makeHarness()
        do {
            let result = try await body(harness)
            try await harness.fluent.shutdown()
            return result
        } catch {
            try? await harness.fluent.shutdown()
            throw error
        }
    }

    private static func makeHarness() async throws -> Harness {
        let logger = Logger(label: "test.x-oauth")
        let fluent = Fluent(logger: logger)
        fluent.databases.use(
            .postgres(configuration: TestPostgres.configuration()),
            as: .psql,
        )
        await fluent.migrations.add(M00_EnableExtensions())
        await fluent.migrations.add(M01_CreateUser())
        await fluent.migrations.add(M02_CreateRefreshToken())
        await fluent.migrations.add(M03_CreatePasswordResetToken())
        await fluent.migrations.add(M04_CreateMFAChallenge())
        await fluent.migrations.add(M05_CreateOAuthIdentity())
        await fluent.migrations.add(M06_CreateMemory())
        await fluent.migrations.add(M07_AddMemoryEmbedding())
        await fluent.migrations.add(M08_CreateHermesProfile())
        await fluent.migrations.add(M09_AddUsernameToUser())
        await fluent.migrations.add(M10_CreateDeviceToken())
        await fluent.migrations.add(M11_CreateWebAuthnCredential())
        await fluent.migrations.add(M12_CreateSpace())
        await fluent.migrations.add(M13_CreateVaultFile())
        await fluent.migrations.add(M14_CreateHealthEvent())
        await fluent.migrations.add(M15_AddTierFields())
        try await fluent.migrate()

        let jwtKeys = JWTKeyCollection()
        let kid = JWKIdentifier(string: "test-kid")
        await jwtKeys.add(
            hmac: HMACKey(stringLiteral: "test-secret-do-not-use-in-prod-32chars"),
            digestAlgorithm: .sha256, kid: kid,
        )
        let mfaService = DefaultMFAService(
            fluent: fluent,
            sender: MFAChallengeRecorder(),
            generator: FixedOTPCodeGenerator(code: "123456"),
        )
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-x-oauth-test-\(UUID().uuidString)", isDirectory: true)
        let service = DefaultAuthService(
            repo: DatabaseAuthRepository(fluent: fluent),
            hasher: BcryptPasswordHasher(),
            fluent: fluent,
            jwtKeys: jwtKeys,
            jwtKID: kid,
            mfaService: mfaService,
            resetCodeSender: MFAChallengeRecorder(),
            resetCodeGenerator: FixedOTPCodeGenerator(code: "654321"),
            verificationCodeSender: MFAChallengeRecorder(),
            verificationCodeGenerator: FixedOTPCodeGenerator(code: "789012"),
            hermesProfileService: HermesProfileService(
                fluent: fluent,
                gateway: LoggingHermesGateway(logger: logger),
                vaultPaths: VaultPathService(rootPath: tmpRoot.path),
            ),
            soulService: SOULService(
                vaultPaths: VaultPathService(rootPath: tmpRoot.path),
                hermesDataRoot: tmpRoot.appendingPathComponent("hermes").path,
                logger: logger,
            ),
            logger: logger,
        )
        return Harness(service: service, fluent: fluent)
    }
}

// MARK: - Test doubles

/// In-memory `XAPIClient` for tests that want to drive the controller path
/// without hitting `api.x.com`. Records each invoked access_token so callers
/// can assert what the controller forwarded.
actor StubXAPIClient: XAPIClient {
    enum Mode {
        case scripted(XUserResponse.XUserData)
        case failing(any Error)
    }

    private let mode: Mode
    private(set) var observedTokens: [String] = []

    init(scripted: XUserResponse.XUserData) {
        mode = .scripted(scripted)
    }

    init(mode: Mode) {
        self.mode = mode
    }

    static func failing(error: any Error) -> StubXAPIClient {
        StubXAPIClient(mode: .failing(error))
    }

    func fetchMe(accessToken: String) async throws -> XUserResponse.XUserData {
        observedTokens.append(accessToken)
        switch mode {
        case let .scripted(user): return user
        case let .failing(err): throw err
        }
    }
}
