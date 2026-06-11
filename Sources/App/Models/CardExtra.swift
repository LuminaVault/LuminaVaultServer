import Foundation

/// Free-form structured metadata stored on a `KanbanCard` (`extra` JSONB
/// column, M72). Currently carries card→Job promotion config; namespaced under
/// `job` so future card add-ons get their own keys without colliding.
struct CardExtra: Codable, Equatable {
    var job: CardJobConfig?

    init(job: CardJobConfig? = nil) {
        self.job = job
    }
}

/// Structured execution config for a card promoted to a scheduled Job
/// (gap #1 — deterministic, no free-text inference). The user supplies
/// `cron`/`domain`/`prompt`/`spaceID`; the server fills `skillName`/`jobSlug`/
/// `promotedAt` when the job is authored.
struct CardJobConfig: Codable, Equatable {
    /// Skill catalog source the authored job lives under. Always "vault" today.
    var source: String
    /// Cron expression, e.g. "0 9 * * 1". Required for recurring jobs.
    var cron: String?
    /// One-shot fire time (UTC) — gap #10. Mutually exclusive with `cron`.
    var runAt: Date?
    /// Domain hint (stocks/sports/ai/…) — steers the job's block output.
    var domain: String?
    /// What the job should do each run; becomes the skill body. When nil the
    /// promote endpoint falls back to the card's `body`.
    var prompt: String?
    /// Target space for result filing (`SkillRunner.fileJobResultIfNeeded`).
    var spaceID: UUID?
    /// Slug of the authored vault skill — set by the server on promotion. Its
    /// presence marks the card as already promoted (idempotency guard).
    var jobSlug: String?
    /// When the card was promoted (UTC).
    var promotedAt: Date?

    init(
        source: String = "vault",
        cron: String? = nil,
        runAt: Date? = nil,
        domain: String? = nil,
        prompt: String? = nil,
        spaceID: UUID? = nil,
        jobSlug: String? = nil,
        promotedAt: Date? = nil
    ) {
        self.source = source
        self.cron = cron
        self.runAt = runAt
        self.domain = domain
        self.prompt = prompt
        self.spaceID = spaceID
        self.jobSlug = jobSlug
        self.promotedAt = promotedAt
    }
}
