@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import JWTKit
import Logging
import Testing

/// HER-86 — verifies the default `SOUL.md` lands on disk for every fresh
/// register (and OAuth net-new), and that the rollback path leaves no
/// orphan user row if the SOUL write fails. Run with `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct SOULInitTests {
    fileprivate struct Harness {
        let service: DefaultAuthService
        let fluent: Fluent
        let vaultRoot: URL
    }

    private static func withHarness<T: Sendable>(
        _ body: @Sendable (Harness) async throws -> T
    ) async throws -> T {
        try await withTestFluentHarness(label: "test.soul", setup: makeHarness(fluent:)) { harness in
            do {
                let result = try await body(harness)
                try? FileManager.default.removeItem(at: harness.vaultRoot)
                return result
            } catch {
                try? FileManager.default.removeItem(at: harness.vaultRoot)
                throw error
            }
        }
    }

    private static func makeHarness(fluent: Fluent) async throws -> Harness {
        let logger = Logger(label: "test.soul")
        // Full app migration list — a hand-maintained subset drifts as the
        // User model grows columns (register INSERTs every field and PSQL
        // errors on any missing column).
        await registerMigrations(on: fluent)
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
            ),
            logger: logger
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
    func `vault init writes default SOUL for fresh register`() async throws {
        // HER-35 moved the SOUL bootstrap from register into the
        // `POST /v1/vault/create` handshake (`VaultInitService` →
        // `SOULService.initIfMissing`). Drive that step explicitly here.
        try await Self.withHarness { h in
            let username = Self.randomUsername()
            let response = try await h.service.register(
                email: Self.randomEmail(),
                username: username,
                password: "CorrectHorseBatteryStaple1!"
            )

            let user = try #require(
                try await User.query(on: h.fluent.db()).filter(\.$username == username).first()
            )
            let soul = SOULService(
                vaultPaths: VaultPathService(rootPath: h.vaultRoot.path),
                hermesDataRoot: h.vaultRoot.appendingPathComponent("hermes").path,
                logger: Logger(label: "test.soul.init")
            )
            #expect(try soul.initIfMissing(for: user) == true)

            let soulPath = h.vaultRoot
                .appendingPathComponent("tenants")
                .appendingPathComponent(response.userId.uuidString)
                .appendingPathComponent("raw")
                .appendingPathComponent(SOULService.fileName)

            #expect(FileManager.default.fileExists(atPath: soulPath.path), "SOUL.md missing at \(soulPath.path)")

            let body = try String(contentsOf: soulPath, encoding: .utf8)
            #expect(body.contains("# SOUL.md"))
            #expect(body.contains("username: \(username)"))
            #expect(SOULCore.containsCanonicalCore(body))
            #expect(body.contains("## Identity"))
            #expect(body.contains("## Chat voice"))
            #expect(body.contains("## What matters to me"))
        }
    }

    @Test
    func `register is idempotent does not overwrite existing SOUL`() async throws {
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
    func `soul service writes valid UTF 8 markdown`() {
        // Pure unit test on the template — no DB needed.
        let body = SOULDefaultTemplate.render(username: "alice")
        #expect(body.contains("username: alice"))
        #expect(body.contains("---"))
        #expect(body.data(using: .utf8) != nil)
    }
}
