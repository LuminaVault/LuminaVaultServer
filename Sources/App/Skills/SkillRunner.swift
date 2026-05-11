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
    private let eventBus: EventBus
    private let logger: Logger
    private var eventSubscriptions: [Task<Void, Never>] = []

    init(
        catalog: SkillCatalog,
        fluent: Fluent,
        vaultPaths: VaultPathService,
        capGuard: SkillRunCapGuard,
        eventBus: EventBus,
        logger: Logger,
    ) {
        self.catalog = catalog
        self.fluent = fluent
        self.vaultPaths = vaultPaths
        self.capGuard = capGuard
        self.eventBus = eventBus
        self.logger = logger
    }

    /// HER-171: subscribe to every event type the runner cares about.
    /// Idempotent — repeated calls are no-ops. Cancels prior subscriptions
    /// first so a hot-reload path doesn't double-subscribe.
    ///
    /// HER-171 scope: log receipt only. HER-169 replaces these loops with
    /// real on_event skill dispatch (catalog lookup by tenant → manifests
    /// whose `metadata.on_event` includes the event type → run()).
    func startEventSubscriptions() {
        for task in eventSubscriptions { task.cancel() }
        eventSubscriptions.removeAll()
        for type in SkillEventType.allCases {
            let stream = eventBus.subscribe(eventType: type)
            let log = logger
            let task = Task<Void, Never> {
                for await event in stream {
                    log.info("skills.runner received event=\(event.type.rawValue) tenant=\(event.tenantID.uuidString) payloadKeys=\(event.payload.keys.sorted().joined(separator: ","))")
                    // HER-169: load tenant's catalog → filter by on_event →
                    // dispatch each matching skill via run(skill:tenantID:...).
                }
            }
            eventSubscriptions.append(task)
        }
        logger.info("skills.runner event subscriptions started: \(SkillEventType.allCases.count) streams")
    }

    /// Cancels every active subscription Task. Safe to call multiple times.
    /// Wired from the App lifecycle on shutdown so streams don't leak.
    func stopEventSubscriptions() {
        for task in eventSubscriptions { task.cancel() }
        eventSubscriptions.removeAll()
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
