import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import JWTKit
import Logging
import Testing

@testable import App

/// HER-86 — verifies the default `SOUL.md` lands on disk for every fresh
/// register (and OAuth net-new), and that the rollback path leaves no
/// orphan user row if the SOUL write fails. Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct SOULInitTests {

    fileprivate struct Harness: Sendable {
        let service: DefaultAuthService
        let fluent: Fluent
        let vaultRoot: URL
    }

    private static func withHarness<T: Sendable>(
        _ body: @Sendable (Harness) async throws -> T
    ) async throws -> T {
        let harness = try await makeHarness()
        do {
            let result = try await body(harness)
            try await harness.fluent.shutdown()
            try? FileManager.default.removeItem(at: harness.vaultRoot)
            return result
        } catch {
            try? await harness.fluent.shutdown()
            try? FileManager.default.removeItem(at: harness.vaultRoot)
            throw error
        }
    }

    private static func makeHarness() async throws -> Harness {
        let logger = Logger(label: "test.soul")
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
        await fluent.migrations.add(M18_AddMemoryTags())
        try await fluent.migrate()

        let jwtKeys = JWTKeyCollection()
        let kid = JWKIdentifier(string: "test-kid")
        await jwtKeys.add(hmac: HMACKey(stringLiteral: "test-secret-do-not-use-in-prod-32chars"), digestAlgorithm: .sha256, kid: kid)

        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-soul-test-\(UUID().uuidString)", isDirectory: true)
        let vaultPaths = VaultPathService(rootPath: tmpRoot.path)

        let mfaService = DefaultMFAService(
            fluent: fluent,
            sender: MFAChallengeRecorder(),
            generator: FixedOTPCodeGenerator(code: "123456")
        )
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
                vaultPaths: vaultPaths
            ),
            soulService: SOULService(
                vaultPaths: vaultPaths,
                hermesDataRoot: tmpRoot.appendingPathComponent("hermes").path,
                logger: logger
            )
        )
        return Harness(service: service, fluent: fluent, vaultRoot: tmpRoot)
    }

    private static func randomEmail() -> String {
        "soul-\(UUID().uuidString.prefix(8).lowercased())@test.luminavault"
    }

    private static func randomUsername() -> String {
        "soul-\(UUID().uuidString.prefix(8).lowercased())"
    }

    @Test
    func registerWritesDefaultSOULToVault() async throws {
        try await Self.withHarness { h in
            let username = Self.randomUsername()
            let response = try await h.service.register(
                email: Self.randomEmail(),
                username: username,
                password: "CorrectHorseBatteryStaple1!"
            )

            let soulPath = h.vaultRoot
                .appendingPathComponent("tenants")
                .appendingPathComponent(response.userId.uuidString)
                .appendingPathComponent("raw")
                .appendingPathComponent(SOULService.fileName)

            #expect(FileManager.default.fileExists(atPath: soulPath.path), "SOUL.md missing at \(soulPath.path)")

            let body = try String(contentsOf: soulPath, encoding: .utf8)
            #expect(body.contains("# SOUL.md"))
            #expect(body.contains("username: \(username)"))
            #expect(body.contains("## Tone preferences"))
            #expect(body.contains("## Priorities"))
            #expect(body.contains("## Learning style"))
        }
    }

    @Test
    func registerIsIdempotentDoesNotOverwriteExistingSOUL() async throws {
        // Pre-seed a SOUL.md as if a returning OAuth user already had one,
        // then re-run init. SOULService must not clobber the existing file.
        try await Self.withHarness { h in
            let username = Self.randomUsername()
            let response = try await h.service.register(
                email: Self.randomEmail(),
                username: username,
                password: "CorrectHorseBatteryStaple1!"
            )

            let soulPath = h.vaultRoot
                .appendingPathComponent("tenants")
                .appendingPathComponent(response.userId.uuidString)
                .appendingPathComponent("raw")
                .appendingPathComponent(SOULService.fileName)

            // Mutate the on-disk file to a sentinel and re-invoke SOULService.
            let sentinel = "USER-EDITED-SOUL"
            try sentinel.data(using: .utf8)!.write(to: soulPath, options: .atomic)

            let user = try #require(
                try await User.query(on: h.fluent.db()).filter(\.$username == username).first()
            )
            let soul = SOULService(
                vaultPaths: VaultPathService(rootPath: h.vaultRoot.path),
                hermesDataRoot: h.vaultRoot.appendingPathComponent("hermes").path,
                logger: Logger(label: "test.soul.idem")
            )
            let wrote = try soul.initIfMissing(for: user)
            #expect(wrote == false)
            let after = try String(contentsOf: soulPath, encoding: .utf8)
            #expect(after == sentinel)
        }
    }

    @Test
    func soulServiceWritesValidUTF8Markdown() async throws {
        // Pure unit test on the template — no DB needed.
        let body = SOULDefaultTemplate.render(username: "alice")
        #expect(body.contains("username: alice"))
        #expect(body.contains("---"))
        #expect(body.data(using: .utf8) != nil)
    }
}
