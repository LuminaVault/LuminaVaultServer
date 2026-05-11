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
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/:name/run", use: runSkill)
    }

    @Sendable
    func runSkill(_: Request, ctx: AppRequestContext) async throws -> HTTPResponse.Status {
        _ = try ctx.requireIdentity()
        guard let _ = ctx.parameters.get("name") else {
            throw HTTPError(.badRequest, message: "skill name required")
        }
        throw HTTPError(.notImplemented, message: "HER-148 scaffold — SkillRunner lands in HER-169")
    }
}
