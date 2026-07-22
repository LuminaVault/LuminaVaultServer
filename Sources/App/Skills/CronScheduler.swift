import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import ServiceLifecycle

/// `ServiceLifecycle.Service` that wakes once per minute and dispatches
/// any `(tenant, enabled skill)` pair whose cron expression — resolved
/// against the user's timezone — matches THIS minute. Concurrency is
/// bounded by `maxConcurrent` (HER-170 default 4) so 100 users firing the
/// same minute don't melt the agent loop.
///
/// ## Constraints
/// - **In-process, single-replica.** Multi-replica = double-fire. When
///   we scale out, add Postgres-advisory-lock leader election (out of
///   scope for HER-170; tracked in docs/jobs.md).
/// - **Next-occurrence semantics**, not catch-up. Downtime spanning a
///   scheduled minute does NOT replay the missed run on restart — we only
///   ever evaluate the CURRENT minute. `last_run_at` advances even on
///   failures so a broken skill can't block subsequent windows.
actor CronScheduler: Service {
    /// Minimum time between ticks in production. `tick(at:)` is exposed
    /// so tests can drive deterministically.
    private let tickInterval: Duration
    private let maxConcurrent: Int
    private let catalog: SkillCatalog
    private let runner: SkillRunner
    private let fluent: Fluent
    private let push: APNSNotificationService?
    private let logger: Logger

    init(
        catalog: SkillCatalog,
        runner: SkillRunner,
        fluent: Fluent,
        push: APNSNotificationService? = nil,
        logger: Logger,
        tickInterval: Duration = .seconds(60),
        maxConcurrent: Int = 4
    ) {
        self.catalog = catalog
        self.runner = runner
        self.fluent = fluent
        self.push = push
        self.logger = logger
        self.tickInterval = tickInterval
        self.maxConcurrent = maxConcurrent
    }

    func run() async throws {
        logger.info("skills.cron.scheduler started (tick=\(tickInterval), max=\(maxConcurrent))")
        // Align first tick to next minute boundary so a restart at HH:MM:42
        // doesn't shift every per-minute tick by 42 seconds for the rest of
        // the process lifetime.
        try? await Task.sleep(for: .seconds(secondsUntilNextMinute(now: Date())))
        while !Task.isCancelled {
            let now = Date()
            do {
                let dispatched = try await tick(at: now)
                if dispatched > 0 {
                    logger.info("skills.cron.tick dispatched=\(dispatched) at=\(now)")
                }
            } catch {
                logger.warning("skills.cron.tick error \(error)")
            }
            try? await Task.sleep(for: tickInterval)
        }
    }

    /// Single tick — returns the number of skills dispatched. Pure-ish:
    /// reads from Fluent, calls `runner.run`, persists `last_*` columns.
    /// Exposed so tests can drive ticks at specific instants without
    /// waiting for the real clock.
    @discardableResult
    func tick(at now: Date) async throws -> Int {
        let pairs = try await loadEnabledPairs()
        var due: [DuePair] = []
        for pair in pairs {
            // One-shot (#10) takes precedence over any cron. Fire once when the
            // instant has arrived (catch-up: >=, like reminders); the row is
            // disabled after dispatch so it never reloads. `lastRunAt >= runAt`
            // guards a same-tick re-fire before the disable lands.
            if let runAt = pair.runAt {
                guard now >= runAt else { continue }
                if let last = pair.lastRunAt, last >= runAt {
                    continue
                }
                due.append(pair)
                continue
            }
            guard let scheduleRaw = pair.schedule else { continue }
            guard let expression = try? CronExpression(scheduleRaw) else {
                logger.warning("skills.cron skipping bad schedule \(scheduleRaw) tenant=\(pair.tenantID)")
                continue
            }
            let timeZone = TimeZone(identifier: pair.timezone) ?? .gmt
            guard expression.matches(now, in: timeZone) else { continue }
            // Single-fire-per-minute: if last_run_at is already in this
            // same wall-clock minute (in user TZ), skip — defends against
            // tick-jitter or a manual run that just happened.
            if let last = pair.lastRunAt,
               sameMinute(last, now, in: timeZone)
            {
                continue
            }
            due.append(pair)
        }
        guard !due.isEmpty else { return 0 }
        await dispatchBounded(due, now: now)
        return due.count
    }

    // MARK: - Bounded dispatch

    private func dispatchBounded(_ pairs: [DuePair], now: Date) async {
        await withTaskGroup(of: Void.self) { group in
            var queue = pairs.makeIterator()
            var inFlight = 0

            func spawnNext() {
                guard let next = queue.next() else { return }
                inFlight += 1
                group.addTask { [self] in
                    await dispatch(pair: next, now: now)
                }
            }
            // Fill up to maxConcurrent slots.
            for _ in 0 ..< min(maxConcurrent, pairs.count) {
                spawnNext()
            }
            // Drain + refill — keeps at most `maxConcurrent` running.
            while inFlight > 0 {
                _ = await group.next()
                inFlight -= 1
                spawnNext()
            }
        }
    }

    /// Runs a single skill; persists outcome to `skills_state.last_*`.
    /// Failures NEVER throw out — next-occurrence semantics demand the
    /// row's `last_run_at` advance regardless, otherwise a broken skill
    /// would block its own future runs forever.
    private func dispatch(pair: DuePair, now: Date) async {
        let label = "skill=\(pair.skillName) tenant=\(pair.tenantID)"
        var status = "ok"
        var errorString: String?
        do {
            _ = try await runner.run(
                skill: pair.manifest,
                tenantID: pair.tenantID,
                tier: pair.tier,
                profileUsername: pair.username,
                trigger: .cron
            )
        } catch {
            status = "error"
            errorString = String(describing: error)
            logger.warning("skills.cron \(label) failed: \(error)")
        }
        do {
            try await persistRunState(pair: pair, at: now, status: status, error: errorString)
        } catch {
            logger.warning("skills.cron \(label) state persist failed: \(error)")
        }
        // HER-Cron — notify the user that a scheduled skill fired, but only
        // when the skill carries an APNS category (opt-in per skill via
        // SkillsState.apnsCategory) and the run succeeded. Best-effort.
        if status == "ok", let push, pair.apnsCategory != nil {
            do {
                try await push.notifyCron(
                    userID: pair.tenantID,
                    skillName: pair.skillName,
                    body: "Your \(pair.skillName) job just ran."
                )
            } catch {
                logger.warning("skills.cron \(label) push failed: \(error)")
            }
        }
    }

    // MARK: - Fluent IO

    /// Pair returned by the loader — a denormalized join of
    /// `users` + `skills_state` + the in-memory `SkillManifest`.
    struct DuePair: Equatable {
        let tenantID: UUID
        let username: String
        let timezone: String
        let tier: String
        let skillName: String
        let source: String // "builtin" | "vault"
        let schedule: String?
        /// One-shot fire time (#10). Non-nil ⇒ one-shot job: fired once when
        /// `now >= runAt`, then the row is disabled.
        let runAt: Date?
        let lastRunAt: Date?
        /// HER-Cron — per-skill APNS opt-in. When non-nil, a successful cron
        /// run fires a `notifyCron` push.
        let apnsCategory: String?
        let manifest: SkillManifest

        static func == (lhs: DuePair, rhs: DuePair) -> Bool {
            lhs.tenantID == rhs.tenantID
                && lhs.skillName == rhs.skillName
                && lhs.source == rhs.source
        }
    }

    /// Load every (user, enabled skill) pair. The catalog merges builtin
    /// + vault manifests; we filter to enabled rows only and join with
    /// the user's timezone + tier.
    private func loadEnabledPairs() async throws -> [DuePair] {
        guard !fluent.databases.ids().isEmpty else { return [] }
        let users: [User]
        do {
            users = try await User.query(on: fluent.db()).all()
        } catch {
            return []
        }
        var pairs: [DuePair] = []
        for user in users {
            let tenantID = try user.requireID()
            let manifests = await (try? catalog.manifests(for: tenantID)) ?? []
            guard !manifests.isEmpty else { continue }
            let states = try await SkillsState.query(on: fluent.db())
                .filter(\.$id == tenantID)
                .filter(\.$enabled == true)
                .all()
            let stateByKey: [String: SkillsState] = Dictionary(
                uniqueKeysWithValues: states.map { ("\($0.source):\($0.name)", $0) }
            )
            for manifest in manifests {
                let key = "\(manifest.source.rawValue):\(manifest.name)"
                let state = stateByKey[key]
                // Legacy Jobs linked to an Automation 2.0 workflow are
                // dispatched by WorkflowScheduler. Keeping the state row
                // preserves old APIs without firing the job twice.
                if state?.workflowID != nil {
                    continue
                }
                // No row at all → treat as enabled with manifest defaults
                // (user hasn't customized; the catalog says it's available).
                let enabled = state?.enabled ?? true
                guard enabled else { continue }
                let schedule = state?.scheduleOverride ?? manifest.schedule
                let runAt = state?.runAt
                // Include the pair if it has either a cron schedule or a
                // one-shot run_at; otherwise it's not schedulable.
                guard schedule != nil || runAt != nil else { continue }
                pairs.append(DuePair(
                    tenantID: tenantID,
                    username: user.username,
                    timezone: user.timezone,
                    tier: user.tier,
                    skillName: manifest.name,
                    source: manifest.source.rawValue,
                    schedule: schedule,
                    runAt: runAt,
                    lastRunAt: state?.lastRunAt,
                    apnsCategory: state?.apnsCategory,
                    manifest: manifest
                ))
            }
        }
        return pairs
    }

    private func persistRunState(
        pair: DuePair,
        at now: Date,
        status: String,
        error: String?
    ) async throws {
        guard !fluent.databases.ids().isEmpty else { return }
        let row: SkillsState
        do {
            row = try await SkillsState.query(on: fluent.db())
                .filter(\.$id == pair.tenantID)
                .filter(\.$source == pair.source)
                .filter(\.$name == pair.skillName)
                .first() ?? SkillsState(
                    tenantID: pair.tenantID,
                    source: pair.source,
                    name: pair.skillName
                )
        } catch {
            return
        }
        row.lastRunAt = now
        row.lastStatus = status
        row.lastError = error
        // One-shot (#10): fired — disable so it never reloads. last_run_at is
        // also stamped, so even a same-tick reload before commit is guarded.
        if pair.runAt != nil {
            row.enabled = false
        }
        try await row.save(on: fluent.db())
    }

    // MARK: - Helpers

    private func sameMinute(_ a: Date, _ b: Date, in timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let aComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: a)
        let bComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: b)
        return aComponents == bComponents
    }

    private func secondsUntilNextMinute(now: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let seconds = calendar.dateComponents([.second], from: now).second ?? 0
        return max(1, 60 - seconds)
    }
}
