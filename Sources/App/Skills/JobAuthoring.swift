import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import SQLKit

/// Authors a recurring Job as a vault cron skill: writes `skills/<slug>/SKILL.md`
/// (cron in frontmatter) and upserts the `skills_state` row `CronScheduler`
/// reads. Shared by `JobsController` (POST /v1/jobs) and Kanban card→Job
/// promotion so both paths produce identical, schedulable jobs.
struct JobAuthoring {
    let vaultPaths: VaultPathService
    let fluent: HummingbirdFluent.Fluent
    let logger: Logger

    /// Validates the cron, writes the skill file, and enables it. Returns the
    /// created slug. Idempotent per title (slug derives from title; the
    /// `skills_state` upsert re-enables on conflict).
    /// Authors a job. Exactly one of `cron` (recurring) or `runAt` (one-shot,
    /// #10) must be supplied. Recurring jobs carry the cron in SKILL.md
    /// frontmatter; one-shot jobs omit `schedule` and store `run_at` on
    /// `skills_state` (the scheduler fires once then disables the row).
    @discardableResult
    func author(
        tenantID: UUID,
        title: String,
        cron: String?,
        runAt: Date? = nil,
        domain: String?,
        spec: String,
        spaceID: UUID?,
    ) async throws -> String {
        switch (cron, runAt) {
        case let (cron?, nil):
            guard (try? CronExpression(cron)) != nil else {
                throw HTTPError(.badRequest, message: "invalid cron schedule")
            }
        case (nil, .some):
            break // one-shot
        default:
            throw HTTPError(.badRequest, message: "job requires exactly one of cron or run_at")
        }
        let slug = Self.slug(title)

        // Author the vault skill.
        let dir = vaultPaths.tenantRoot(for: tenantID)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let md = Self.skillMarkdown(slug: slug, title: title, cron: cron, domain: domain, spec: spec)
        try Data(md.utf8).write(to: dir.appendingPathComponent("SKILL.md"), options: .atomic)

        // Enable it + record domain/space for filing (P4), Jobs grouping, and
        // one-shot fire time. ON CONFLICT also resets run_at so re-authoring a
        // recurring job clears any prior one-shot schedule.
        if let sql = fluent.db() as? any SQLDatabase {
            try await sql.raw("""
            INSERT INTO skills_state (tenant_id, source, name, enabled, domain, space_id, run_at)
            VALUES (\(bind: tenantID), 'vault', \(bind: slug), TRUE, \(bind: domain), \(bind: spaceID), \(bind: runAt))
            ON CONFLICT (tenant_id, source, name) DO UPDATE
              SET enabled = TRUE, domain = EXCLUDED.domain, space_id = EXCLUDED.space_id, run_at = EXCLUDED.run_at
            """).run()
        }

        let when = cron ?? runAt.map { "once@\($0)" } ?? "-"
        logger.info("job authored tenant=\(tenantID) slug=\(slug) when=\(when) domain=\(domain ?? "-")")
        return slug
    }

    // MARK: - Authoring helpers

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
        let base: String = core.isEmpty
            ? String(UUID().uuidString.prefix(8)).lowercased()
            : String(core.prefix(40))
        return "job-\(base)"
    }

    /// Renders a valid `SKILL.md` (SkillManifestParser-compatible frontmatter)
    /// for a scheduled job. The body asks for P2 block output, domain-adaptive.
    /// `cron` nil ⇒ one-shot: the `schedule` line is omitted (the fire time
    /// lives on `skills_state.run_at`).
    static func skillMarkdown(slug: String, title: String, cron: String?, domain: String?, spec: String) -> String {
        let domainLine = domain.map { "Domain: \($0)." } ?? ""
        let scheduleLine = cron.map { "\n          schedule: \"\($0)\"" } ?? ""
        return """
        ---
        name: \(slug)
        description: \(title)
        license: MIT
        allowed-tools: session_search vault_read
        metadata:
          capability: medium\(scheduleLine)
          on_event: []
          daily_run_cap: { trial: 1, pro: 6, ultimate: 24 }
          maxInputTokens: 8000
          outputs:
            - kind: apns_digest
        ---
        You are a LuminaVault job: "\(title)".
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
