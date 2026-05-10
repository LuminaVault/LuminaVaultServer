import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import App

/// Cross-tenant data isolation. Each test creates two distinct tenant UUIDs
/// and verifies that `TenantModel.query(on: db, tenantID:)` strictly partitions
/// rows. Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct TenantIsolationTests {

    /// Wraps each test with Fluent setup and guaranteed shutdown so the
    /// AsyncKit ConnectionPool deinit assertion can't crash the runner.
    private static func withFluent<T: Sendable>(
        _ body: @Sendable (Fluent) async throws -> T
    ) async throws -> T {
        let fluent = try await makeFluent()
        do {
            let result = try await body(fluent)
            try await fluent.shutdown()
            return result
        } catch {
            try? await fluent.shutdown()
            throw error
        }
    }

    private static func makeFluent() async throws -> Fluent {
        let logger = Logger(label: "test.tenant")
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
        return fluent
    }

    private static func makeUser(_ id: UUID, _ slug: String) -> User {
        User(
            id: id,
            email: "\(slug)@test.luminavault",
            username: slug,
            passwordHash: "stub-hash-\(slug)"
        )
    }

    private static func slug(_ tag: String) -> String {
        "\(tag)\(UUID().uuidString.prefix(6).lowercased())"
    }

    @Test
    func refreshTokenQueryFiltersByTenant() async throws {
        try await Self.withFluent { fluent in
            let db = fluent.db()
            let t1 = UUID(); let t2 = UUID()
            try await Self.makeUser(t1, Self.slug("ru1")).save(on: db)
            try await Self.makeUser(t2, Self.slug("ru2")).save(on: db)

            try await RefreshToken(tenantID: t1, tokenHash: UUID().uuidString, expiresAt: Date().addingTimeInterval(3600)).save(on: db)
            try await RefreshToken(tenantID: t2, tokenHash: UUID().uuidString, expiresAt: Date().addingTimeInterval(3600)).save(on: db)

            let t1Tokens = try await RefreshToken.query(on: db, tenantID: t1).all()
            let t2Tokens = try await RefreshToken.query(on: db, tenantID: t2).all()
            #expect(t1Tokens.count == 1 && t1Tokens[0].tenantID == t1)
            #expect(t2Tokens.count == 1 && t2Tokens[0].tenantID == t2)
        }
    }

    @Test
    func memoryQueryFiltersByTenant() async throws {
        try await Self.withFluent { fluent in
            let db = fluent.db()
            let t1 = UUID(); let t2 = UUID()
            try await Self.makeUser(t1, Self.slug("mu1")).save(on: db)
            try await Self.makeUser(t2, Self.slug("mu2")).save(on: db)

            try await Memory(tenantID: t1, content: "alice secret").save(on: db)
            try await Memory(tenantID: t2, content: "bob secret").save(on: db)

            let t1Mem = try await Memory.query(on: db, tenantID: t1).all()
            let t2Mem = try await Memory.query(on: db, tenantID: t2).all()
            #expect(t1Mem.map(\.content) == ["alice secret"])
            #expect(t2Mem.map(\.content) == ["bob secret"])
        }
    }

    @Test
    func oauthIdentityQueryFiltersByTenant() async throws {
        try await Self.withFluent { fluent in
            let db = fluent.db()
            let t1 = UUID(); let t2 = UUID()
            try await Self.makeUser(t1, Self.slug("ou1")).save(on: db)
            try await Self.makeUser(t2, Self.slug("ou2")).save(on: db)

            try await OAuthIdentity(tenantID: t1, provider: "google", providerUserID: UUID().uuidString, email: "a@x.io", emailVerified: true).save(on: db)
            try await OAuthIdentity(tenantID: t2, provider: "apple", providerUserID: UUID().uuidString, email: "b@y.io", emailVerified: true).save(on: db)

            let t1OA = try await OAuthIdentity.query(on: db, tenantID: t1).all()
            let t2OA = try await OAuthIdentity.query(on: db, tenantID: t2).all()
            #expect(t1OA.map(\.provider) == ["google"])
            #expect(t2OA.map(\.provider) == ["apple"])
        }
    }

    @Test
    func mfaChallengeQueryFiltersByTenant() async throws {
        try await Self.withFluent { fluent in
            let db = fluent.db()
            let t1 = UUID(); let t2 = UUID()
            try await Self.makeUser(t1, Self.slug("mfa1")).save(on: db)
            try await Self.makeUser(t2, Self.slug("mfa2")).save(on: db)

            try await MFAChallenge(
                tenantID: t1, purpose: "login", channel: "email", destination: "a@x.io",
                codeHash: "h1", expiresAt: Date().addingTimeInterval(600)
            ).save(on: db)
            try await MFAChallenge(
                tenantID: t2, purpose: "login", channel: "email", destination: "b@y.io",
                codeHash: "h2", expiresAt: Date().addingTimeInterval(600)
            ).save(on: db)

            let t1Ch = try await MFAChallenge.query(on: db, tenantID: t1).all()
            let t2Ch = try await MFAChallenge.query(on: db, tenantID: t2).all()
            #expect(t1Ch.count == 1 && t1Ch[0].destination == "a@x.io")
            #expect(t2Ch.count == 1 && t2Ch[0].destination == "b@y.io")
        }
    }

    @Test
    func crossTenantDeleteOnlyAffectsOwner() async throws {
        try await Self.withFluent { fluent in
            let db = fluent.db()
            let t1 = UUID(); let t2 = UUID()
            try await Self.makeUser(t1, Self.slug("del1")).save(on: db)
            try await Self.makeUser(t2, Self.slug("del2")).save(on: db)

            try await RefreshToken(tenantID: t1, tokenHash: UUID().uuidString, expiresAt: Date().addingTimeInterval(3600)).save(on: db)
            try await RefreshToken(tenantID: t2, tokenHash: UUID().uuidString, expiresAt: Date().addingTimeInterval(3600)).save(on: db)

            try await RefreshToken.query(on: db, tenantID: t1).delete()

            let remainingT1 = try await RefreshToken.query(on: db, tenantID: t1).all()
            let remainingT2 = try await RefreshToken.query(on: db, tenantID: t2).all()
            #expect(remainingT1.isEmpty)
            #expect(remainingT2.count == 1)
        }
    }

    @Test
    func hermesProfileServiceEnsureScopesByTenant() async throws {
        try await Self.withFluent { fluent in
            let db = fluent.db()
            let t1 = UUID(); let t2 = UUID()
            let u1 = Self.makeUser(t1, Self.slug("hps1"))
            let u2 = Self.makeUser(t2, Self.slug("hps2"))
            try await u1.save(on: db)
            try await u2.save(on: db)

            let tmpRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("lv-hps-test-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tmpRoot) }

            let service = HermesProfileService(
                fluent: fluent,
                gateway: LoggingHermesGateway(logger: Logger(label: "test.hermes")),
                vaultPaths: VaultPathService(rootPath: tmpRoot.path)
            )

            let p1 = try await service.ensure(for: u1)
            let p2 = try await service.ensure(for: u2)
            #expect(p1.tenantID == t1)
            #expect(p2.tenantID == t2)
            #expect(p1.hermesProfileID == "hermes-\(u1.username)")
            #expect(p2.hermesProfileID == "hermes-\(u2.username)")

            let t1Profiles = try await HermesProfile.query(on: db, tenantID: t1).all()
            let t2Profiles = try await HermesProfile.query(on: db, tenantID: t2).all()
            #expect(t1Profiles.count == 1)
            #expect(t2Profiles.count == 1)

            let p1Again = try await service.ensure(for: u1)
            #expect(p1Again.id == p1.id)
            #expect(try await HermesProfile.query(on: db, tenantID: t1).count() == 1)
        }
    }
}
