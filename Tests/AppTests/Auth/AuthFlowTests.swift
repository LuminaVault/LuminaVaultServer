import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import JWTKit
import Logging
import Testing

@testable import App

/// End-to-end auth flow tests — register/login/MFA/refresh/logout/reset.
/// Each test creates ephemeral users with random usernames and emails so
/// there's no cross-test contamination on a shared schema.
/// Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct AuthFlowTests {

    fileprivate struct Harness: Sendable {
        let service: DefaultAuthService
        let fluent: Fluent
        let recorder: MFAChallengeRecorder
    }

    /// Setup + guaranteed Fluent shutdown so the AsyncKit ConnectionPool
    /// deinit assertion doesn't crash the runner.
    private static func withHarness<T: Sendable>(
        _ body: @Sendable (Harness) async throws -> T
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
        let logger = Logger(label: "test.auth")
        let fluent = Fluent(logger: logger)
        fluent.databases.use(
            .postgres(configuration: .init(
                hostname: "127.0.0.1",
                port: 5433,
                username: "hermes",
                password: "luminavault",
                database: "hermes_db",
                tls: .disable
            )),
            as: .psql
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
        try await fluent.migrate()

        let jwtKeys = JWTKeyCollection()
        let kid = JWKIdentifier(string: "test-kid")
        await jwtKeys.add(hmac: HMACKey(stringLiteral: "test-secret-do-not-use-in-prod-32chars"), digestAlgorithm: .sha256, kid: kid)

        let recorder = MFAChallengeRecorder()
        let mfaService = DefaultMFAService(
            fluent: fluent,
            sender: recorder,
            generator: FixedOTPCodeGenerator(code: "123456")
        )
        let resetRecorder = MFAChallengeRecorder()
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-auth-test-\(UUID().uuidString)", isDirectory: true)
        let service = DefaultAuthService(
            repo: DatabaseAuthRepository(fluent: fluent),
            hasher: BcryptPasswordHasher(),
            fluent: fluent,
            jwtKeys: jwtKeys,
            jwtKID: kid,
            mfaService: mfaService,
            resetCodeSender: resetRecorder,
            resetCodeGenerator: FixedOTPCodeGenerator(code: "654321"),
            hermesProfileService: HermesProfileService(
                fluent: fluent,
                gateway: LoggingHermesGateway(logger: logger),
                vaultPaths: VaultPathService(rootPath: tmpRoot.path)
            )
        )
        return Harness(service: service, fluent: fluent, recorder: recorder)
    }

    private static func randomEmail() -> String {
        "auth-\(UUID().uuidString.prefix(8).lowercased())@test.luminavault"
    }

    private static func randomUsername() -> String {
        "auth-\(UUID().uuidString.prefix(8).lowercased())"
    }

    @Test
    func registerHappyPathCreatesUserAndHermesProfile() async throws {
        try await Self.withHarness { h in
            let email = Self.randomEmail()
            let username = Self.randomUsername()

            let response = try await h.service.register(email: email, username: username, password: "CorrectHorseBatteryStaple1!")
            #expect(!response.accessToken.isEmpty)
            #expect(!response.refreshToken.isEmpty)
            #expect(response.email == email.lowercased())

            let user = try await User.query(on: h.fluent.db()).filter(\.$username == username).first()
            #expect(user != nil)
            #expect(user?.username == username)

            let profile = try await HermesProfile
                .query(on: h.fluent.db(), tenantID: try user!.requireID())
                .first()
            #expect(profile != nil)
            #expect(profile?.hermesProfileID == "hermes-\(username)")
            #expect(profile?.status == "ready")
        }
    }

    @Test
    func registerRejectsDuplicateUsername() async throws {
        try await Self.withHarness { h in
            let username = Self.randomUsername()
            _ = try await h.service.register(email: Self.randomEmail(), username: username, password: "CorrectHorseBatteryStaple1!")
            await #expect(throws: (any Error).self) {
                _ = try await h.service.register(email: Self.randomEmail(), username: username, password: "CorrectHorseBatteryStaple1!")
            }
        }
    }

    @Test
    func registerRejectsDuplicateEmail() async throws {
        try await Self.withHarness { h in
            let email = Self.randomEmail()
            _ = try await h.service.register(email: email, username: Self.randomUsername(), password: "CorrectHorseBatteryStaple1!")
            await #expect(throws: (any Error).self) {
                _ = try await h.service.register(email: email, username: Self.randomUsername(), password: "CorrectHorseBatteryStaple1!")
            }
        }
    }

    @Test
    func registerRejectsReservedUsername() async throws {
        try await Self.withHarness { h in
            await #expect(throws: (any Error).self) {
                _ = try await h.service.register(email: Self.randomEmail(), username: "admin", password: "CorrectHorseBatteryStaple1!")
            }
        }
    }

    @Test
    func registerRejectsWeakPassword() async throws {
        try await Self.withHarness { h in
            await #expect(throws: (any Error).self) {
                _ = try await h.service.register(email: Self.randomEmail(), username: Self.randomUsername(), password: "short")
            }
        }
    }

    @Test
    func loginHappyPath() async throws {
        try await Self.withHarness { h in
            let email = Self.randomEmail()
            _ = try await h.service.register(email: email, username: Self.randomUsername(), password: "CorrectHorseBatteryStaple1!")
            let response = try await h.service.login(email: email, password: "CorrectHorseBatteryStaple1!", requireMFA: false)
            #expect(!response.accessToken.isEmpty)
            #expect(response.mfaRequired == nil || response.mfaRequired == false)
        }
    }

    @Test
    func loginRejectsWrongPassword() async throws {
        try await Self.withHarness { h in
            let email = Self.randomEmail()
            _ = try await h.service.register(email: email, username: Self.randomUsername(), password: "CorrectHorseBatteryStaple1!")
            await #expect(throws: (any Error).self) {
                _ = try await h.service.login(email: email, password: "WrongPassword12345!", requireMFA: false)
            }
        }
    }

    @Test
    func loginWithMFAReturnsChallengeNotTokens() async throws {
        try await Self.withHarness { h in
            let email = Self.randomEmail()
            _ = try await h.service.register(email: email, username: Self.randomUsername(), password: "CorrectHorseBatteryStaple1!")
            let response = try await h.service.login(email: email, password: "CorrectHorseBatteryStaple1!", requireMFA: true)
            #expect(response.mfaRequired == true)
            #expect(response.mfaChallengeId != nil)
            #expect(response.accessToken.isEmpty)
            #expect(await h.recorder.lastCode == "123456")
        }
    }

    @Test
    func mfaVerifyIssuesTokens() async throws {
        try await Self.withHarness { h in
            let email = Self.randomEmail()
            _ = try await h.service.register(email: email, username: Self.randomUsername(), password: "CorrectHorseBatteryStaple1!")
            let pending = try await h.service.login(email: email, password: "CorrectHorseBatteryStaple1!", requireMFA: true)
            let challengeID = try #require(pending.mfaChallengeId)
            let verified = try await h.service.verifyMFA(challengeID: challengeID, code: "123456")
            #expect(!verified.accessToken.isEmpty)
            #expect(!verified.refreshToken.isEmpty)
        }
    }

    @Test
    func refreshRotatesTokenAndRevokesOld() async throws {
        try await Self.withHarness { h in
            let registered = try await h.service.register(email: Self.randomEmail(), username: Self.randomUsername(), password: "CorrectHorseBatteryStaple1!")
            let original = registered.refreshToken

            let refreshed = try await h.service.refresh(refreshToken: original)
            #expect(refreshed.refreshToken != original)
            #expect(!refreshed.accessToken.isEmpty)

            await #expect(throws: (any Error).self) {
                _ = try await h.service.refresh(refreshToken: original)
            }
        }
    }

    @Test
    func logoutRevokesRefreshToken() async throws {
        try await Self.withHarness { h in
            let registered = try await h.service.register(email: Self.randomEmail(), username: Self.randomUsername(), password: "CorrectHorseBatteryStaple1!")
            try await h.service.revokeRefresh(refreshToken: registered.refreshToken)
            await #expect(throws: (any Error).self) {
                _ = try await h.service.refresh(refreshToken: registered.refreshToken)
            }
        }
    }

    @Test
    func resetPasswordEndToEnd() async throws {
        try await Self.withHarness { h in
            let email = Self.randomEmail()
            _ = try await h.service.register(email: email, username: Self.randomUsername(), password: "CorrectHorseBatteryStaple1!")

            try await h.service.forgotPassword(email: email)
            let reset = try await h.service.resetPassword(email: email, code: "654321", newPassword: "NewPasswordCorrectHorse1!")
            #expect(!reset.accessToken.isEmpty)

            let login = try await h.service.login(email: email, password: "NewPasswordCorrectHorse1!", requireMFA: false)
            #expect(!login.accessToken.isEmpty)

            await #expect(throws: (any Error).self) {
                _ = try await h.service.login(email: email, password: "CorrectHorseBatteryStaple1!", requireMFA: false)
            }
        }
    }
}

// MARK: - Test doubles

actor MFAChallengeRecorder: EmailOTPSender {
    var lastCode: String?
    var lastDestination: String?
    func send(code: String, to email: String, purpose: String) async throws {
        self.lastCode = code
        self.lastDestination = email
    }
}

struct FixedOTPCodeGenerator: OTPCodeGenerator {
    let code: String
    func generate() -> String { code }
}
