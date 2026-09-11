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
/// The behaviour under test: a user on their own Hermes or their own key must
/// not be 402'd for inference the platform never paid for.
///
/// Chat, memory query and capture are now free on every tier but `archived`,
/// so the BYO exemption no longer shows up on those capabilities — it is only
/// observable on the ones a non-paying tier still lacks (`memoGenerator`,
/// `kbCompile`, `memoryCompile`, `healthIngest`, `skillBuiltinRun`). Those are
/// the probes used below.
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
        hasUsableCredential: (@Sendable (UUID) async -> Bool)? = nil,
        platformFunded: Bool = false
    ) async throws -> HTTPResponse.Status {
        let router = Router(context: AppRequestContext.self)
        router.add(middleware: StubContextMiddleware(user: user(tier: tier), resolution: resolution))
        router.add(middleware: EntitlementMiddleware(
            requires: capability,
            enforcementEnabled: true,
            hasUsableCredential: hasUsableCredential,
            platformFunded: platformFunded
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
        let status = try await Self.probe(capability: .memoGenerator, tier: .lapsed, resolution: nil)
        #expect(status.code == 402)
    }

    /// A managed-Hermes tenant is on our compute, so the paywall stands.
    @Test
    func `resolving to the managed hermes is not a BYO signal`() async throws {
        let status = try await Self.probe(capability: .memoGenerator, tier: .lapsed, resolution: Self.managedHermes)
        #expect(status.code == 402)
    }

    @Test
    func `a credential closure returning false does not exempt`() async throws {
        let status = try await Self.probe(
            capability: .kbCompile,
            tier: .lapsed,
            resolution: nil,
            hasUsableCredential: { _ in false }
        )
        #expect(status.code == 402)
    }

    /// Chat needs no BYO signal any more — it is free outright. Kept as its
    /// own case so that if chat is ever re-gated, this fails loudly rather
    /// than hiding behind an exemption.
    @Test
    func `chat needs no BYO signal on a non-paying tier`() async throws {
        for tier in [UserTier.free, .lapsed] {
            for capability in [Capability.chat, .memoryQuery, .capture] {
                let status = try await Self.probe(capability: capability, tier: tier, resolution: nil)
                #expect(status == .ok, "\(tier).\(capability) should not need a BYO signal")
            }
        }
    }

    // MARK: - BYO passes

    @Test
    func `a lapsed user on their own hermes is not charged`() async throws {
        for capability in [Capability.memoGenerator, .memoryCompile, .healthIngest, .kbCompile, .skillBuiltinRun] {
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
            capability: .memoryCompile,
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

    /// `/v1/transcribe` (Groq), `/v1/tts` (OpenAI) and `/v1/vision` (Cohere)
    /// spend a platform key no matter whose Hermes the tenant brought — none
    /// of the three adapters takes a `UserCredentialStore`. Exempting them
    /// handed a lapsed BYO user 200 transcriptions, 1000 TTS calls and 200
    /// vision embeds a day on our account.
    ///
    /// Note the capability is `.chat` for two of them — the same capability
    /// that must stay exempt on `/v1/llm` — which is why this is a property
    /// of the route and not of the capability.
    @Test
    func `platform-funded routes stay gated for BYO`() async throws {
        for capability in [Capability.chat, .memoryQuery] {
            let status = try await Self.probe(
                capability: capability,
                tier: .lapsed,
                resolution: Self.ownHermes,
                hasUsableCredential: { _ in true },
                platformFunded: true
            )
            #expect(status.code == 402, "\(capability) on a platform-funded route must not be exempt")
        }
    }

    /// The money leak that making chat free would otherwise open.
    ///
    /// `free` and `lapsed` hold `.chat` and `.memoryQuery` outright, so
    /// entitlement alone would let them onto `/v1/transcribe` (Groq),
    /// `/v1/tts` (OpenAI) and `/v1/vision` (Cohere) — none of which has a free
    /// lane or a bring-your-own path. `platformFunded` carries a tier floor of
    /// `trial` for exactly this reason.
    @Test
    func `platform-funded routes are closed to non-paying tiers`() async throws {
        for tier in [UserTier.free, .lapsed, .archived] {
            for capability in [Capability.chat, .memoryQuery] {
                let status = try await Self.probe(
                    capability: capability,
                    tier: tier,
                    resolution: nil,
                    platformFunded: true
                )
                #expect(status.code == 402, "\(tier).\(capability) must not spend a platform key")
            }
        }
    }

    /// The floor is `trial`, not `pro` — a trial user is a prospective
    /// customer with a clock running, which is who these routes sell to.
    @Test
    func `platform-funded routes stay open to trial and above`() async throws {
        for tier in [UserTier.trial, .pro, .ultimate] {
            let status = try await Self.probe(
                capability: .chat,
                tier: tier,
                resolution: nil,
                platformFunded: true
            )
            #expect(status == .ok, "\(tier) should reach a platform-funded route")
        }
    }

    /// A `tier_override` clears the floor, so founders and testers on a
    /// granted `ultimate` keep transcription and TTS.
    @Test
    func `a tier override clears the platform-funded floor`() async throws {
        let router = Router(context: AppRequestContext.self)
        let overridden = Self.user(tier: .free)
        overridden.tierOverride = TierOverride.ultimate.rawValue
        router.add(middleware: StubContextMiddleware(user: overridden, resolution: nil))
        router.add(middleware: EntitlementMiddleware(
            requires: .chat,
            enforcementEnabled: true,
            platformFunded: true
        ))
        router.get("/probe") { _, _ -> String in "ok" }
        let app = Application(router: router)
        try await app.test(.router) { client in
            try await client.execute(uri: "/probe", method: .get) { #expect($0.status == .ok) }
        }
    }

    /// The same capability, same tenant, same signals — exempt when the route
    /// runs on their key. This pair is the whole distinction.
    @Test
    func `the same capability passes on a user-funded route`() async throws {
        let status = try await Self.probe(
            capability: .memoGenerator,
            tier: .lapsed,
            resolution: Self.ownHermes,
            hasUsableCredential: { _ in true },
            platformFunded: false
        )
        #expect(status == .ok)
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
