@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

/// HER-217 — `HermesEndpointResolver` unit tests. Drives the resolver
/// directly against the suite's isolated test Postgres so we cover
/// the row-absent default path, the row-present override path, the
/// SSRF-rejection error path, and the decrypt-failure path.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct HermesEndpointResolverTests {
    private static let testMasterKeyBase64 = Data((0 ..< 32).map { UInt8($0) }).base64EncodedString()
    private static let defaultURL = URL(string: "http://default.hermes.test")!

    /// HER-310 — Spins up a Fluent + SecretBox + SSRFGuard stack, hands
    /// them to `body`, and guarantees `fluent.shutdown()` runs before
    /// returning.
    ///
    /// The shutdown discipline lives in `withTestFluent` rather than being
    /// repeated here. This helper used to hand-roll it, and also built an
    /// `Application` it immediately discarded (`_ = app`) for a connection
    /// it then recreated by hand. That application owned a second `Fluent`
    /// that nothing ever shut down, because the app was never run through
    /// its service lifecycle — so on release, `Databases.deinit` reached
    /// `EventLoopGroupConnectionPool.deinit`, tripped AsyncKit's
    /// `shutdown() was not called before deinit` precondition, and took the
    /// whole test binary down with an illegal instruction. It killed the
    /// integration run mid-flight: the suites that had not finished never
    /// reported, and `swift test` exited before printing a summary.
    ///
    /// The hand-rolled configuration also named `TestPostgres.database` —
    /// the *base* template database — instead of this suite's clone. Holding
    /// connections there blocks the concurrent `CREATE DATABASE ... TEMPLATE`
    /// that every other suite needs (see `PrimeBaseDatabaseTests`).
    /// `TestPostgres.configuration()`, which `withTestFluent` uses, resolves
    /// to the isolated clone.
    private static func withResolver<Result>(
        allowPrivate: Bool = true,
        ssrfResolver: any HostResolver = SSRFGuardTests.StubResolver(
            answers: [
                "127.0.0.1": ["127.0.0.1"],
                "user.hermes.test": ["93.184.216.34"],
                "evil.test": ["10.0.0.1"],
            ]
        ),
        _ body: (HermesEndpointResolver, Fluent, SecretBox) async throws -> Result
    ) async throws -> Result {
        try await withTestFluent(label: "lv.test.resolver") { fluent in
            let secretBox = try SecretBox(masterKeyBase64: testMasterKeyBase64)
            let ssrfGuard = SSRFGuard(
                allowPrivateRanges: allowPrivate,
                requireHTTPS: false,
                resolver: ssrfResolver
            )
            let resolver = HermesEndpointResolver(
                fluent: fluent,
                secretBox: secretBox,
                ssrfGuard: ssrfGuard,
                defaultBaseURL: defaultURL,
                logger: Logger(label: "lv.test.resolver")
            )
            return try await body(resolver, fluent, secretBox)
        }
    }

    @Test
    func `returns managed default when no row exists`() async throws {
        try await Self.withResolver { resolver, _, _ in
            // Fresh tenantID with no matching row.
            let tenantID = UUID()
            let resolution = try await resolver.resolve(tenantID: tenantID)

            #expect(resolution.isUserOverride == false)
            #expect(resolution.baseURL == Self.defaultURL)
            #expect(resolution.authHeader == nil)
        }
    }

    @Test
    func `returns override when row exists and decrypts auth header`() async throws {
        try await Self.withResolver { resolver, fluent, secretBox in
            // Provision a user so the FK cascade is satisfied.
            let user = User()
            user.email = "resolver-\(UUID().uuidString.prefix(8))@test.luminavault"
            user.username = "resolver-\(UUID().uuidString.prefix(8))"
            user.passwordHash = "x"
            user.tier = "trial"
            user.tierOverride = "none"
            try await user.save(on: fluent.db())
            // M90: tenant_id references vaults(id). Registration provisions the
            // vault; a test saving a User directly must do the same.
            try await DefaultAuthService.ensurePersonalVault(for: user, on: fluent.db())
            let tenantID = try user.requireID()

            let sealed = try secretBox.seal("Bearer abc-123", tenantID: tenantID)
            let row = UserHermesConfig()
            row.tenantID = tenantID
            row.baseURL = "https://user.hermes.test"
            row.authHeaderCiphertext = sealed.ciphertext
            row.authHeaderNonce = sealed.nonce
            try await row.save(on: fluent.db())

            let resolution = try await resolver.resolve(tenantID: tenantID)
            #expect(resolution.isUserOverride == true)
            #expect(resolution.baseURL.absoluteString == "https://user.hermes.test")
            #expect(resolution.authHeader == "Bearer abc-123")
        }
    }

    @Test
    func `throws ssrfRejected when stored URL fails revalidation`() async throws {
        try await Self.withResolver(allowPrivate: false) { resolver, fluent, _ in
            let user = User()
            user.email = "resolver-\(UUID().uuidString.prefix(8))@test.luminavault"
            user.username = "resolver-\(UUID().uuidString.prefix(8))"
            user.passwordHash = "x"
            user.tier = "trial"
            user.tierOverride = "none"
            try await user.save(on: fluent.db())
            // M90: tenant_id references vaults(id). Registration provisions the
            // vault; a test saving a User directly must do the same.
            try await DefaultAuthService.ensurePersonalVault(for: user, on: fluent.db())
            let tenantID = try user.requireID()

            // Stored URL was valid at PUT time but now resolves to RFC1918.
            let row = UserHermesConfig()
            row.tenantID = tenantID
            row.baseURL = "https://evil.test"
            try await row.save(on: fluent.db())

            await #expect(throws: HermesEndpointResolver.ResolutionError.self) {
                _ = try await resolver.resolve(tenantID: tenantID)
            }
        }
    }

    @Test
    func `throws decryptFailed when ciphertext is corrupt`() async throws {
        try await Self.withResolver { resolver, fluent, secretBox in
            let user = User()
            user.email = "resolver-\(UUID().uuidString.prefix(8))@test.luminavault"
            user.username = "resolver-\(UUID().uuidString.prefix(8))"
            user.passwordHash = "x"
            user.tier = "trial"
            user.tierOverride = "none"
            try await user.save(on: fluent.db())
            // M90: tenant_id references vaults(id). Registration provisions the
            // vault; a test saving a User directly must do the same.
            try await DefaultAuthService.ensurePersonalVault(for: user, on: fluent.db())
            let tenantID = try user.requireID()

            let sealed = try secretBox.seal("Bearer abc", tenantID: tenantID)
            // Flip a bit through `[UInt8]`, as `SecretBoxTests` does. `Data`
            // is not guaranteed to be zero-based: CryptoKit's
            // `SealedBox.ciphertext` is a view into the combined box, so it
            // starts at 12 — past the nonce — and `seal`'s `ciphertext + tag`
            // keeps that offset. Subscripting the result at a literal 0 is
            // out of bounds and traps.
            var bytes = [UInt8](sealed.ciphertext)
            bytes[0] ^= 0xFF
            let corruptCT = Data(bytes)

            let row = UserHermesConfig()
            row.tenantID = tenantID
            row.baseURL = "https://user.hermes.test"
            row.authHeaderCiphertext = corruptCT
            row.authHeaderNonce = sealed.nonce
            try await row.save(on: fluent.db())

            await #expect(throws: HermesEndpointResolver.ResolutionError.decryptFailed) {
                _ = try await resolver.resolve(tenantID: tenantID)
            }
        }
    }
}
