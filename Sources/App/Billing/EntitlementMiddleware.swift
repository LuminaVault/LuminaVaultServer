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

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response,
    ) async throws -> Response {
        guard enforcementEnabled else {
            return try await next(request, context)
        }
        let user = try context.requireIdentity()
        guard user.entitled(for: requires) else {
            return try Self.paywallResponse(for: requires)
        }
        return try await next(request, context)
    }

    static func paywallResponse(for capability: Capability) throws -> Response {
        let paywallId = paywallID(for: capability)
        let body = try JSONEncoder().encode(PaywallResponse(paywall: true, paywallId: paywallId))
        return Response(
            status: .init(code: 402, reasonPhrase: "Payment Required"),
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(bytes: body)),
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
             .memoryQuery, .memoGenerator, .skillBuiltinRun, .kbCompile:
            false
        }
    }
}
