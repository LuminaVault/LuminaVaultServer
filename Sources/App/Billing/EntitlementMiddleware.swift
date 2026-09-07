import Foundation
import Hummingbird

struct PaywallResponse: Codable, ResponseEncodable {
    let paywall: Bool
    let paywallId: String
}

struct EntitlementMiddleware: RouterMiddleware {
    typealias Context = AppRequestContext

    let requires: Capability
    let enforcementEnabled: Bool
    /// Whether the tenant has a provider credential the router could spend.
    ///
    /// Optional because most groups can answer the BYO question for free from
    /// `context.hermesResolution`, and this closure costs up to nine DB reads
    /// on a cold cache. It is supplied on the groups where the Hermes signal is
    /// unavailable, and consulted only after the free check has failed.
    let hasUsableCredential: (@Sendable (UUID) async -> Bool)?

    init(
        requires: Capability,
        enforcementEnabled: Bool,
        hasUsableCredential: (@Sendable (UUID) async -> Bool)? = nil
    ) {
        self.requires = requires
        self.enforcementEnabled = enforcementEnabled
        self.hasUsableCredential = hasUsableCredential
    }

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard enforcementEnabled else {
            return try await next(request, context)
        }
        let user = try context.requireIdentity()
        if user.entitled(for: requires) {
            return try await next(request, context)
        }
        // Not entitled by tier. Before charging, ask whether we are billed for
        // this at all: a tenant on their own Hermes or their own key pays the
        // provider directly. See `BYOEntitlementPolicy`.
        if try await byoExemption(user: user, context: context) != nil {
            return try await next(request, context)
        }
        return try Self.paywallResponse(for: requires)
    }

    /// Cheap signal first: `hermesResolution` is already populated by
    /// `HermesResolutionMiddleware` on the groups that mount it, so this is a
    /// zero-I/O read there. The credential lookup only runs when that is
    /// absent and the capability could actually be exempted.
    private func byoExemption(user: User, context: Context) async throws -> BYOExemption? {
        guard !requires.requiresUltimate, user.tierEnum != .archived else { return nil }

        if let exemption = BYOEntitlementPolicy.exemption(
            for: requires,
            tier: user.tierEnum,
            input: .init(
                hasOwnHermes: context.hermesResolution?.isUserOverride == true,
                hasUsableUserCredential: false
            )
        ) {
            return exemption
        }

        guard let hasUsableCredential else { return nil }
        let tenantID = try user.requireID()
        return await BYOEntitlementPolicy.exemption(
            for: requires,
            tier: user.tierEnum,
            input: .init(hasOwnHermes: false, hasUsableUserCredential: hasUsableCredential(tenantID))
        )
    }

    static func paywallResponse(for capability: Capability) throws -> Response {
        let paywallId = paywallID(for: capability)
        let body = try JSONEncoder().encode(PaywallResponse(paywall: true, paywallId: paywallId))
        return Response(
            status: .init(code: 402, reasonPhrase: "Payment Required"),
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(bytes: body))
        )
    }

    static func paywallID(for capability: Capability) -> String {
        capability.requiresUltimate ? "ultimate_upsell" : "default"
    }
}

extension Capability {
    var requiresUltimate: Bool {
        switch self {
        case .skillVaultRun, .privacyBYOKey, .privacyContextRouter, .mlxOnDevice:
            true
        case .vaultRead, .vaultExport, .capture, .healthIngest, .chat,
             .memoryQuery, .memoGenerator, .skillBuiltinRun, .kbCompile, .memoryCompile,
             .workflowAutomation:
            false
        }
    }
}
