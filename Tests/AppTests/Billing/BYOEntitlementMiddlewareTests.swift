@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Synchronization
import Testing

/// `EntitlementMiddleware` over a minimal router — no Postgres, no
/// `buildApplication`.
///
/// Booting the full app with `lv.secretMasterKey` set (which is what the BYO
/// signals require) starts the container manager and friends, and the test
/// harness never tears them down. The middleware is what changed, so mount
/// just the middleware.
///
/// The behaviour under test: everyone becomes `lapsed` 14 days after signup
/// (`LapseArchiverJob`), and `lapsed` denies chat, capture, memory search and
/// the knowledge graph — so a user on their own Hermes or their own key was
/// 402'd for inference the platform never paid for.
struct BYOEntitlementMiddlewareTests {
    /// Stands in for `JWTAuthenticator` + `HermesResolutionMiddleware`.
    private struct StubContextMiddleware: RouterMiddleware {
        typealias Context = AppRequestContext
        let user: User
        let resolution: HermesEndpointResolver.Resolution?

        func handle(
            _ request: Request,
            context: Context,
            next: (Request, Context) async throws -> Response
        ) async throws -> Response {
            var context = context
            context.identity = user
            context.hermesResolution = resolution
            return try await next(request, context)
        }
    }

    private static func user(tier: UserTier) -> User {
        User(
            id: UUID(),
            email: "byo@test.luminavault",
            username: "byo",
            passwordHash: "x",
            tier: tier.rawValue
        )
    }

    private static let ownHermes = HermesEndpointResolver.Resolution(
        baseURL: URL(string: "http://100.105.117.67:8642")!,
        authHeader: "Bearer x",
        isUserOverride: true
    )
    private static let managedHermes = HermesEndpointResolver.Resolution(
        baseURL: URL(string: "http://managed.internal:8642")!,
        authHeader: nil,
        isUserOverride: false
    )

    /// Returns the status of `GET /probe` behind the middleware under test.
    private static func probe(
        capability: Capability,
        tier: UserTier,
        resolution: HermesEndpointResolver.Resolution?,
        hasUsableCredential: (@Sendable (UUID) async -> Bool)? = nil
    ) async throws -> HTTPResponse.Status {
        let router = Router(context: AppRequestContext.self)
        router.add(middleware: StubContextMiddleware(user: user(tier: tier), resolution: resolution))
        router.add(middleware: EntitlementMiddleware(
            requires: capability,
            enforcementEnabled: true,
            hasUsableCredential: hasUsableCredential
        ))
        router.get("/probe") { _, _ -> String in "ok" }

        let app = Application(router: router)
        return try await app.test(.router) { client in
            try await client.execute(uri: "/probe", method: .get) { $0.status }
        }
    }

    // MARK: - The charge still applies without a BYO signal

    @Test
    func `a lapsed user with nothing of their own is still charged`() async throws {
        let status = try await Self.probe(capability: .chat, tier: .lapsed, resolution: nil)
        #expect(status.code == 402)
    }

    /// A managed-Hermes tenant is on our compute, so the paywall stands.
    @Test
    func `resolving to the managed hermes is not a BYO signal`() async throws {
        let status = try await Self.probe(capability: .chat, tier: .lapsed, resolution: Self.managedHermes)
        #expect(status.code == 402)
    }

    @Test
    func `a credential closure returning false does not exempt`() async throws {
        let status = try await Self.probe(
            capability: .memoryQuery,
            tier: .lapsed,
            resolution: nil,
            hasUsableCredential: { _ in false }
        )
        #expect(status.code == 402)
    }

    // MARK: - BYO passes

    @Test
    func `a lapsed user on their own hermes is not charged`() async throws {
        for capability in [Capability.chat, .capture, .memoryQuery, .memoGenerator, .memoryCompile, .healthIngest] {
            let status = try await Self.probe(capability: capability, tier: .lapsed, resolution: Self.ownHermes)
            #expect(status == .ok, "\(capability) should pass for a BYO-Hermes tenant")
        }
    }

    /// `/v1/knowledge` (the Brain tab) has no Hermes middleware upstream, so
    /// its exemption depends entirely on the credential closure. Its 402 was
    /// reaching the app as a paywall sheet over the screen.
    @Test
    func `a lapsed user with their own key is not charged`() async throws {
        let status = try await Self.probe(
            capability: .memoryQuery,
            tier: .lapsed,
            resolution: nil,
            hasUsableCredential: { _ in true }
        )
        #expect(status == .ok)
    }

    // MARK: - What BYO does not buy

    @Test
    func `ultimate-only capabilities stay gated for BYO`() async throws {
        let status = try await Self.probe(
            capability: .skillVaultRun,
            tier: .lapsed,
            resolution: Self.ownHermes,
            hasUsableCredential: { _ in true }
        )
        #expect(status.code == 402)
    }

    @Test
    func `archived stays closed even with BYO`() async throws {
        let status = try await Self.probe(
            capability: .chat,
            tier: .archived,
            resolution: Self.ownHermes,
            hasUsableCredential: { _ in true }
        )
        #expect(status.code == 402)
    }

    // MARK: - Unchanged behaviour

    @Test
    func `enforcement disabled still bypasses everything`() async throws {
        let router = Router(context: AppRequestContext.self)
        router.add(middleware: StubContextMiddleware(user: Self.user(tier: .lapsed), resolution: nil))
        router.add(middleware: EntitlementMiddleware(requires: .chat, enforcementEnabled: false))
        router.get("/probe") { _, _ -> String in "ok" }
        let app = Application(router: router)
        try await app.test(.router) { client in
            try await client.execute(uri: "/probe", method: .get) { #expect($0.status == .ok) }
        }
    }

    @Test
    func `a paying tier passes without consulting the credential store`() async throws {
        let consulted = Mutex(false)
        let status = try await Self.probe(
            capability: .chat,
            tier: .pro,
            resolution: nil,
            hasUsableCredential: { _ in
                consulted.withLock { $0 = true }
                return false
            }
        )
        #expect(status == .ok)
        #expect(consulted.withLock { $0 } == false, "the tier check should short-circuit before any DB work")
    }
}
