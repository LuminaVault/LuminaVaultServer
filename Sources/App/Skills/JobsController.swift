import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

/// SkillDTO already conforms to ResponseEncodable in SkillsController.
extension JobProposalDTO: @retroactive ResponseEncodable {}

/// Lumina Jobs P3 — chat→job detection + creation.
///   POST /v1/jobs/detect  — classify a chat message → JobProposalDTO
///   POST /v1/jobs         — create a scheduled job (a vault cron skill)
///
/// A created job is authored as `<vaultRoot>/tenants/<id>/skills/<slug>/SKILL.md`
/// (cron in frontmatter) so the existing `SkillCatalog` (vault scanning, P3a)
/// + `CronScheduler` run it like any other skill, and the P1 Jobs UI lists it.
struct JobsController {
    let classifier: JobIntentClassifier
    let authoring: JobAuthoring
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/detect", use: detect)
        router.post("", use: create)
    }

    struct DetectRequest: Decodable { let text: String }

    @Sendable
    func detect(_ req: Request, ctx: AppRequestContext) async throws -> JobProposalDTO {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let body = try await req.decode(as: DetectRequest.self, context: ctx)
        return await classifier.classify(text: body.text, tenantID: tenantID)
    }

    @Sendable
    func create(_ req: Request, ctx: AppRequestContext) async throws -> SkillDTO {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let body = try await req.decode(as: JobCreateRequest.self, context: ctx)
        let slug = try await authoring.author(
            tenantID: tenantID,
            title: body.title,
            cron: body.cron,
            domain: body.domain,
            spec: body.spec,
            spaceID: body.spaceId,
        )
        return SkillDTO(
            id: slug,
            source: .vault,
            name: slug,
            title: body.title,
            descriptionText: body.spec,
            capability: .medium,
            schedule: body.cron,
            enabled: true,
            dailyRunCount: 0,
            dailyRunCap: 0,
            apnsCategory: nil,
            bodyExcerpt: String(body.spec.prefix(160)),
        )
    }
}
