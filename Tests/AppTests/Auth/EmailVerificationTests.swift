import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import JWTKit
import Logging
import Testing

@testable import App

/// HER-87: Email verification flow tests.
/// Mirrors AuthFlowTests harness — service-layer integration against real Postgres at :5433.
/// Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct EmailVerificationTests {

    fileprivate struct Harness: Sendable {
        let service: DefaultAuthService
        let fluent: Fluent
        let verifyRecorder: MFAChallengeRecorder
    }

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
        let logger = Logger(label: "test.verify")
        let fluent = Fluent(logger: logger)
        fluent.databases.use(
            .postgres(configuration: TestPostgres.configuration()),
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
        await fluent.migrations.add(M15_AddTierFields())
        await fluent.migrations.add(M16_CreateEmailVerificationToken())
        await fluent.migrations.add(M17_CreateOnboardingState())
        try await fluent.migrate()

        let jwtKeys = JWTKeyCollection()
        let kid = JWKIdentifier(string: "test-kid")
        await jwtKeys.add(hmac: HMACKey(stringLiteral: "test-secret-do-not-use-in-prod-32chars"), digestAlgorithm: .sha256, kid: kid)

        let mfaService = DefaultMFAService(
            fluent: fluent,
            sender: MFAChallengeRecorder(),
            generator: FixedOTPCodeGenerator(code: "111111")
        )
        let verifyRecorder = MFAChallengeRecorder()
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-verify-test-\(UUID().uuidString)", isDirectory: true)
        let service = DefaultAuthService(
            repo: DatabaseAuthRepository(fluent: fluent),
            hasher: BcryptPasswordHasher(),
            fluent: fluent,
            jwtKeys: jwtKeys,
            jwtKID: kid,
            mfaService: mfaService,
            resetCodeSender: MFAChallengeRecorder(),
            resetCodeGenerator: FixedOTPCodeGenerator(code: "222222"),
            verificationCodeSender: verifyRecorder,
            verificationCodeGenerator: FixedOTPCodeGenerator(code: "789012"),
            hermesProfileService: HermesProfileService(
                fluent: fluent,
                gateway: LoggingHermesGateway(logger: logger),
                vaultPaths: VaultPathService(rootPath: tmpRoot.path)
            ),
            soulService: SOULService(
                vaultPaths: VaultPathService(rootPath: tmpRoot.path),
                hermesDataRoot: tmpRoot.appendingPathComponent("hermes").path,
                logger: logger
            )
        )
        return Harness(service: service, fluent: fluent, verifyRecorder: verifyRecorder)
    }

    private static func randomEmail() -> String {
        "verify-\(UUID().uuidString.prefix(8).lowercased())@test.luminavault"
    }

    private static func randomUsername() -> String {
        "verify-\(UUID().uuidString.prefix(8).lowercased())"
    }

    @Test
    func newUserStartsUnverified() async throws {
        try await Self.withHarness { h in
            let email = Self.randomEmail()
            _ = try await h.service.register(email: email, username: Self.randomUsername(), password: "CorrectHorseBatteryStaple1!")
            let user = try #require(try await User.query(on: h.fluent.db()).filter(\.$email == email.lowercased()).first())
            #expect(user.isVerified == false)
        }
    }

    @Test
    func sendVerificationDeliversCodeToEmail() async throws {
        try await Self.withHarness { h in
            let email = Self.randomEmail()
            _ = try await h.service.register(email: email, username: Self.randomUsername(), password: "CorrectHorseBatteryStaple1!")
            try await h.service.sendVerification(email: email)
            #expect(await h.verifyRecorder.lastCode == "789012")
            #expect(await h.verifyRecorder.lastDestination == email.lowercased())
        }
    }

    @Test
    func sendVerificationIsSilentOnUnknownEmail() async throws {
        try await Self.withHarness { h in
            try await h.service.sendVerification(email: "nobody-\(UUID().uuidString)@test.luminavault")
            #expect(await h.verifyRecorder.lastCode == nil)
        }
    }

    @Test
    func confirmEmailFlipsIsVerifiedAndIsIdempotent() async throws {
        try await Self.withHarness { h in
            let email = Self.randomEmail()
            _ = try await h.service.register(email: email, username: Self.randomUsername(), password: "CorrectHorseBatteryStaple1!")
            try await h.service.sendVerification(email: email)

            try await h.service.confirmEmail(email: email, code: "789012")
            let user = try #require(try await User.query(on: h.fluent.db()).filter(\.$email == email.lowercased()).first())
            #expect(user.isVerified == true)

            // Calling confirm again with the same code is a no-op (idempotent), not a failure.
            try await h.service.confirmEmail(email: email, code: "789012")
        }
    }

    @Test
    func confirmEmailRejectsWrongCode() async throws {
        try await Self.withHarness { h in
            let email = Self.randomEmail()
            _ = try await h.service.register(email: email, username: Self.randomUsername(), password: "CorrectHorseBatteryStaple1!")
            try await h.service.sendVerification(email: email)

            await #expect(throws: (any Error).self) {
                try await h.service.confirmEmail(email: email, code: "000000")
            }
            let user = try #require(try await User.query(on: h.fluent.db()).filter(\.$email == email.lowercased()).first())
            #expect(user.isVerified == false)
        }
    }

    @Test
    func confirmEmailRejectsWhenNoTokenIssued() async throws {
        try await Self.withHarness { h in
            let email = Self.randomEmail()
            _ = try await h.service.register(email: email, username: Self.randomUsername(), password: "CorrectHorseBatteryStaple1!")
            await #expect(throws: (any Error).self) {
                try await h.service.confirmEmail(email: email, code: "789012")
            }
        }
    }

    @Test
    func confirmEmailLocksAfterRepeatedFailures() async throws {
        try await Self.withHarness { h in
            let email = Self.randomEmail()
            _ = try await h.service.register(email: email, username: Self.randomUsername(), password: "CorrectHorseBatteryStaple1!")
            try await h.service.sendVerification(email: email)

            for _ in 0..<5 {
                try? await h.service.confirmEmail(email: email, code: "000000")
            }
            // 6th attempt — token now locked, even with the correct code.
            await #expect(throws: (any Error).self) {
                try await h.service.confirmEmail(email: email, code: "789012")
            }
            let user = try #require(try await User.query(on: h.fluent.db()).filter(\.$email == email.lowercased()).first())
            #expect(user.isVerified == false)
        }
    }
}
