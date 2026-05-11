import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

/// How a skill was triggered. Recorded on `skill_run_log` for audit.
enum SkillTrigger: Hashable {
    case manual
    case cron
    case event(name: String)
}

/// Outcome of a single skill execution. Persisted to `skill_run_log` by
/// `SkillRunner` and surfaced on the `POST /v1/skills/:name/run` response.
struct SkillRunResult: Codable, Hashable {
    let runID: UUID
    let status: String // "ok" | "error"
    let error: String?
    let modelUsed: String?
    let mtokIn: Int
    let mtokOut: Int
    let startedAt: Date
    let endedAt: Date
}

/// Runs a `SkillManifest` against the Hermes agent loop with strict
/// tool gating: dispatch is enforced server-side against the manifest's
/// `allowed-tools`. A skill that didn't declare `memory_upsert` cannot
/// invoke it — the LLM sees a tool-error and cannot bypass.
///
/// Output dispatch (per `outputs[].kind`) writes to vault, queues APNS,
/// upserts memory, or rewrites the source vault file. Both `started_at`
/// and `ended_at` plus `mtok_in`/`mtok_out` are persisted for cost
/// attribution (UsageMeter integration follows in HER-148 billing pass).
///
/// HER-148 scaffold: actor surface only. Real loop lives in HER-169 and
/// mirrors `HermesMemoryService.runAgent` (HermesMemoryService.swift).
actor SkillRunner {
    private let catalog: SkillCatalog
    private let fluent: Fluent
    private let vaultPaths: VaultPathService
    private let capGuard: SkillRunCapGuard
    private let logger: Logger

    init(
        catalog: SkillCatalog,
        fluent: Fluent,
        vaultPaths: VaultPathService,
        capGuard: SkillRunCapGuard,
        logger: Logger,
    ) {
        self.catalog = catalog
        self.fluent = fluent
        self.vaultPaths = vaultPaths
        self.capGuard = capGuard
        self.logger = logger
    }

    /// Runs the skill and returns the result. Persists to `skill_run_log`
    /// + updates `skills_state.last_*` columns.
    ///
    /// HER-193 plug-in points (HER-169 wires them):
    /// 1. Before LLM dispatch — `capGuard.checkAndIncrement(...)`;
    ///    `.deny` becomes `SkillRunCapExceededError`.
    /// 2. After LLM/output dispatch fails — `capGuard.recordFailure(...)`
    ///    so the slot is refunded.
    func run(
        skill _: SkillManifest,
        tenantID _: UUID,
        tier _: String,
        profileUsername _: String,
        trigger _: SkillTrigger,
    ) async throws -> SkillRunResult {
        throw HTTPError(.notImplemented, message: "HER-169 — SkillRunner not yet implemented")
    }
}
