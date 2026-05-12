import Foundation
import Hummingbird
import Logging

/// HTTP surface for the skills runtime.
/// - `POST /v1/skills/:name/run` — manual invocation of a skill for the
///   authenticated tenant. Looks up the manifest via `SkillCatalog`,
///   dispatches to `SkillRunner`, returns the `SkillRunResult`.
///
/// HER-148 scaffold: route registered, handler returns 501 until
/// `SkillRunner` is implemented in HER-169.
struct SkillsController {
    let runner: SkillRunner
    let catalog: SkillCatalog
    let enforcementEnabled: Bool
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/:name/run", use: runSkill)
    }

    @Sendable
    func runSkill(_: Request, ctx: AppRequestContext) async throws -> HTTPResponse.Status {
        let user = try ctx.requireIdentity()
        guard let name = ctx.parameters.get("name") else {
            throw HTTPError(.badRequest, message: "skill name required")
        }
        if enforcementEnabled {
            let manifest = try await catalog.manifest(named: name, for: user.requireID())
            let capability: Capability = manifest?.source == .vault ? .skillVaultRun : .skillBuiltinRun
            guard user.entitled(for: capability) else {
                throw EntitlementDeniedError(capability: capability)
            }
        }
        // HER-169 will dispatch to `runner.run(...)` inside a do/catch
        // that maps `SkillRunCapExceededError` (from the HER-193 guard)
        // via `Self.capExceededHTTPError(_:)` — `429 Too Many Requests`
        // with `Retry-After: <seconds-to-next-user-local-midnight>`.
        throw HTTPError(.notImplemented, message: "HER-148 scaffold — SkillRunner lands in HER-169")
    }

    /// HER-193 — map a cap-guard denial to the conventional `429 +
    /// Retry-After` envelope. Wired up once HER-169 dispatches the run.
    static func capExceededHTTPError(_ error: SkillRunCapExceededError) -> HTTPError {
        HTTPError(
            .tooManyRequests,
            headers: [.retryAfter: String(Int(error.retryAfter.rounded(.up)))],
            message: "daily run cap exceeded for this skill",
        )
    }
}

struct EntitlementDeniedError: HTTPResponseError {
    let capability: Capability

    var status: HTTPResponse.Status {
        .init(code: 402, reasonPhrase: "Payment Required")
    }

    func response(from _: Request, context _: some RequestContext) throws -> Response {
        try EntitlementMiddleware.paywallResponse(for: capability)
    }
}
