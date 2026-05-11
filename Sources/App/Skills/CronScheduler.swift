import Foundation
import HummingbirdFluent
import Logging
import ServiceLifecycle

/// `ServiceLifecycle.Service` that wakes once per minute and dispatches
/// any `(tenant, enabled skill)` pair whose cron expression — resolved
/// against the user's timezone and `last_run_at` — is due. Concurrency
/// is bounded by an internal `TaskGroup` cap (HER-170: max 4 in flight
/// across all tenants).
///
/// ## Constraints
/// - **In-process, single-replica.** Multi-replica = double-fire. When
///   we scale out, add Postgres-advisory-lock leader election (out of
///   scope for HER-170).
/// - **Next-occurrence semantics**, not catch-up. Downtime spanning a
///   scheduled minute does NOT replay the missed run on restart.
///
/// HER-148 scaffold: `Service` conformance + no-op `run()`. Real ticker
/// + cron evaluator land in HER-170. Not yet added to `appServices` in
/// `App+build.swift` — see TODO there.
actor CronScheduler: Service {
    private let catalog: SkillCatalog
    private let runner: SkillRunner
    private let fluent: Fluent
    private let logger: Logger

    init(
        catalog: SkillCatalog,
        runner: SkillRunner,
        fluent: Fluent,
        logger: Logger,
    ) {
        self.catalog = catalog
        self.runner = runner
        self.fluent = fluent
        self.logger = logger
    }

    func run() async throws {
        logger.info("skills.cron.scheduler started (no-op scaffold — HER-170)")
        // HER-170: per-minute tick → query enabled skills_state rows →
        // evaluate cron expr in users.timezone against last_run_at →
        // dispatch due skills to SkillRunner via bounded TaskGroup.
        for await _ in AsyncStream<Void>.makeStream().stream {}
    }
}
