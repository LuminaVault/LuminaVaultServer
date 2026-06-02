@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

/// HER-217 — `HermesEndpointResolver` unit tests. Drives the resolver
/// directly against the test Postgres (via `dbTestReader`) so we cover
/// the row-absent default path, the row-present override path, the
/// SSRF-rejection error path, and the decrypt-failure path.
@Suite(.serialized)
struct HermesEndpointResolverTests {
    private static let testMasterKeyBase64 = Data((0 ..< 32).map { UInt8($0) }).base64EncodedString()
    private static let defaultURL = URL(string: "http://default.hermes.test")!

    /// HER-310 — Spins up a Fluent + SecretBox + SSRFGuard stack, hands
    /// them to `body`, and guarantees `fluent.shutdown()` runs before
    /// returning. Replaces the prior `makeResolver()` + `defer { Task {
    /// try? await fluent.shutdown() } }` pattern, which was racy: the
    /// detached `Task` may not run before `Fluent` deinits, tripping
    /// AsyncKit's `ConnectionPool.shutdown() was not called before
    /// deinit` precondition and SIGILL-ing the whole test binary on
    /// process exit.
    private static func withResolver<Result>(
        allowPrivate: Bool = true,
        ssrfResolver: any HostResolver = SSRFGuardTests.StubResolver(
            answers: [
                "127.0.0.1": ["127.0.0.1"],
                "user.hermes.test": ["93.184.216.34"],
                "evil.test": ["10.0.0.1"],
            ],
        ),
        _ body: (HermesEndpointResolver, Fluent, SecretBox) async throws -> Result,
    ) async throws -> Result {
        let app = try await buildApplication(reader: dbTestReader)
        // Driving the resolver against the *real* services container would
        // require exposing a hook; the cleanest path is to construct a
        // private resolver wired to the same Fluent instance the app uses.
        // `buildApplication` initialises Fluent via `dbTestReader`; we
        // recreate the same connection here for the resolver under test.
        _ = app
        let logger = Logger(label: "lv.test.resolver")
        let fluent = Fluent(logger: logger)
        fluent.databases.use(
            .postgres(configuration: .init(
                hostname: TestPostgres.host,
                port: TestPostgres.port,
                username: TestPostgres.username,
                password: TestPostgres.password,
                database: TestPostgres.database,
                tls: .disable,
            )),
            as: .psql,
        )
        do {
            let secretBox = try SecretBox(masterKeyBase64: testMasterKeyBase64)
            let ssrfGuard = SSRFGuard(
                allowPrivateRanges: allowPrivate,
                requireHTTPS: false,
                resolver: ssrfResolver,
            )
            let resolver = HermesEndpointResolver(
                fluent: fluent,
                secretBox: secretBox,
                ssrfGuard: ssrfGuard,
                defaultBaseURL: defaultURL,
                logger: logger,
            )
            let result = try await body(resolver, fluent, secretBox)
            try await fluent.shutdown()
            return result
        } catch {
            try? await fluent.shutdown()
            throw error
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
            let tenantID = try user.requireID()

            let sealed = try secretBox.seal("Bearer abc", tenantID: tenantID)
            var corruptCT = sealed.ciphertext
            corruptCT[0] ^= 0xFF

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
