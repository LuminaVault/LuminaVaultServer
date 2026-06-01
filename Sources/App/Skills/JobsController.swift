import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared
import Logging
import SQLKit

// SkillDTO already conforms to ResponseEncodable in SkillsController.
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
    let vaultPaths: VaultPathService
    let fluent: HummingbirdFluent.Fluent
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
        guard (try? CronExpression(body.cron)) != nil else {
            throw HTTPError(.badRequest, message: "invalid cron schedule")
        }
        let slug = Self.slug(body.title)

        // Author the vault skill.
        let dir = vaultPaths.tenantRoot(for: tenantID)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let md = Self.skillMarkdown(slug: slug, title: body.title, cron: body.cron, domain: body.domain, spec: body.spec)
        try Data(md.utf8).write(to: dir.appendingPathComponent("SKILL.md"), options: .atomic)

        // Enable it + record domain/space for filing (P4) and Jobs grouping.
        if let sql = fluent.db() as? any SQLDatabase {
            try await sql.raw("""
            INSERT INTO skills_state (tenant_id, source, name, enabled, domain, space_id)
            VALUES (\(bind: tenantID), 'vault', \(bind: slug), TRUE, \(bind: body.domain), \(bind: body.spaceId))
            ON CONFLICT (tenant_id, source, name) DO UPDATE
              SET enabled = TRUE, domain = EXCLUDED.domain, space_id = EXCLUDED.space_id
            """).run()
        }

        logger.info("job created tenant=\(tenantID) slug=\(slug) cron=\(body.cron) domain=\(body.domain ?? "-")")
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

    // MARK: - Authoring

    /// Filesystem-safe, namespaced job slug ("job-daily-stock-prices").
    static func slug(_ title: String) -> String {
        var out = ""
        var lastDash = false
        for ch in title.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        let core = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = core.isEmpty ? UUID().uuidString.prefix(8).lowercased() : core.prefix(40)
        return "job-\(base)"
    }

    /// Renders a valid `SKILL.md` (SkillManifestParser-compatible frontmatter)
    /// for a scheduled job. The body asks for P2 block output, domain-adaptive.
    static func skillMarkdown(slug: String, title: String, cron: String, domain: String?, spec: String) -> String {
        let domainLine = domain.map { "Domain: \($0)." } ?? ""
        return """
        ---
        name: \(slug)
        description: \(title)
        license: MIT
        allowed-tools: session_search vault_read
        metadata:
          capability: medium
          schedule: "\(cron)"
          on_event: []
          daily_run_cap: { trial: 1, pro: 6, ultimate: 24 }
          maxInputTokens: 8000
          outputs:
            - kind: apns_digest
        ---
        You are a recurring LuminaVault job: "\(title)".
        \(domainLine)

        Each run, do exactly this and present the result for the user:
        \(spec)

        Output a SINGLE JSON object: {"markdown":"<short summary>","blocks":[ ... ]}
        using the Lumina block schema (statCard, lineChart, barChart, list, table,
        keyValue, heading, paragraph, badge). Choose the blocks that best present
        this domain's data — e.g. statCard + lineChart for metrics, table/list for
        collections, paragraph for prose. Keep it concise and scannable. Output
        only the JSON, no code fence.
        """
    }
}
