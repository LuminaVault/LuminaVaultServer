@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import JWTKit
import Logging
import Testing

/// HER-29 — signup soft-fail contract. With a degraded Hermes gateway,
/// `register(...)` must still succeed: the User is created, a
/// `status="error"` HermesProfile row is recorded for the daily reconciler,
/// and the access token issues without an `hpid` claim.
@Suite(.serialized)
struct HermesProvisioningLifecycleTests {
    fileprivate struct Harness {
        let service: DefaultAuthService
        let fluent: Fluent
        let jwtKeys: JWTKeyCollection
        let kid: JWKIdentifier
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
        let logger = Logger(label: "test.hermes-lifecycle")
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
        await fluent.migrations.add(M16_CreateEmailVerificationToken())
        try await fluent.migrate()

        let jwtKeys = JWTKeyCollection()
        let kid = JWKIdentifier(string: "test-kid")
        await jwtKeys.add(hmac: HMACKey(stringLiteral: "test-secret-do-not-use-in-prod-32chars"), digestAlgorithm: .sha256, kid: kid)

        let mfaService = DefaultMFAService(
            fluent: fluent,
            sender: MFAChallengeRecorder(),
            generator: FixedOTPCodeGenerator(code: "123456"),
        )
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-hpl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let vaultPaths = VaultPathService(rootPath: tmpRoot.path)

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
                gateway: AlwaysFailingHermesGateway(),
                vaultPaths: vaultPaths,
            ),
            soulService: SOULService(
                vaultPaths: vaultPaths,
                hermesDataRoot: tmpRoot.appendingPathComponent("hermes").path,
                logger: logger,
            ),
            logger: logger,
        )
        return Harness(service: service, fluent: fluent, jwtKeys: jwtKeys, kid: kid)
    }

    @Test
    func `register succeeds with a failing hermes gateway and records an error row`() async throws {
        try await Self.withHarness { harness in
            let slug = "lif\(UUID().uuidString.prefix(6).lowercased())"
            let email = "\(slug)@test.luminavault"
            let username = slug
            let password = "passwordpassword12!"

            let response = try await harness.service.register(
                email: email,
                username: username,
                password: password,
            )

            // Signup still issues tokens despite the gateway being down.
            #expect(!response.accessToken.isEmpty)
            #expect(!response.refreshToken.isEmpty)

            // User row is committed (no rollback).
            let user = try await User.query(on: harness.fluent.db())
                .filter(\.$email == email.lowercased())
                .first()
            #expect(user != nil)
            let tenantID = try #require(try user?.requireID())

            // HermesProfile is left in `error` for the reconciler to heal.
            let profile = try await HermesProfile
                .query(on: harness.fluent.db(), tenantID: tenantID)
                .first()
            #expect(profile?.status == "error")
            #expect(profile?.lastError != nil)
            #expect(profile?.hermesProfileID.hasPrefix("pending-") == true)

            // Access token does NOT carry hpid — downstream services that
            // need a real Hermes endpoint should fall back to a DB lookup
            // and short-circuit when status != "ready".
            let verified = try await harness.jwtKeys.verify(response.accessToken, as: SessionToken.self)
            #expect(verified.hpid == nil)
            #expect(verified.userID == tenantID)
        }
    }
}

// MARK: - Test doubles

private struct AlwaysFailingHermesGateway: HermesGateway {
    struct Down: Error, CustomStringConvertible {
        var description: String { "hermes gateway is intentionally down for lifecycle test" }
    }

    func provisionProfile(tenantID _: UUID, username _: String) async throws -> String {
        throw Down()
    }

    func deleteProfile(hermesProfileID _: String) async throws {}
}
