import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared

enum HermesGatewayApplyError: Error, Equatable {
    case alreadyRunning
}

/// Orchestrates the tenant-scoped "apply gateway config" flow.
///
/// Steps: `writeEnv` (re-seed the tenant's `/opt/data/.env` from the saved
/// gateway rows) → `restartContainer` (`rm -f` + re-`docker run` so the new
/// env takes effect) → `healthCheck` (poll the container's OpenAI gateway).
/// Job state is persisted to `hermes_gateway_apply_jobs` on every transition
/// so the iOS client can reconnect and the server can restart without losing
/// the snapshot. Progress is broadcast to any number of SSE subscribers.
///
/// Concurrency: `actor` isolation serialises all state + DB writes. Each job
/// body runs in a task **owned by this actor** — not `Task.detached` — so it
/// inherits the actor's executor. The request handler returns immediately
/// after `startApply`; the persisted row is the source of truth. Single-flight
/// is per-tenant (one running job per tenant, enforced by a DB check + a
/// partial unique index).
actor HermesGatewayApplyService {
    /// `(port, apiKey) -> healthy`. Hits the container's loopback-published
    /// OpenAI gateway; injected so tests can stub it.
    typealias HealthProbe = @Sendable (_ port: Int, _ apiKey: String) async -> Bool

    private let fluent: Fluent
    private let containerManager: HermesContainerManager
    private let healthProbe: HealthProbe
    private let healthTimeoutSeconds: Int
    private let logger: Logger
    private let now: @Sendable () -> Date

    /// jobID → (subscriberID → continuation). Live SSE fan-out.
    private var subscribers: [UUID: [UUID: AsyncThrowingStream<HermesGatewayApplyEvent, Error>.Continuation]] = [:]
    /// tenantID → running job task, retained so it isn't cancelled early.
    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    private static let pipeline: [HermesGatewayApplyStepID] = [
        .writeEnv, .restartContainer, .healthCheck,
    ]

    init(
        fluent: Fluent,
        containerManager: HermesContainerManager,
        healthProbe: @escaping HealthProbe,
        healthTimeoutSeconds: Int = 60,
        logger: Logger,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fluent = fluent
        self.containerManager = containerManager
        self.healthProbe = healthProbe
        self.healthTimeoutSeconds = healthTimeoutSeconds
        self.logger = logger
        self.now = now
    }

    // MARK: - Public API

    /// Start an apply for `tenantID`. Throws `.alreadyRunning` if one is already
    /// in flight for this tenant. Returns the initial snapshot.
    func startApply(tenantID: UUID) async throws -> HermesGatewayApplyJobStatus {
        if try await hasRunningJob(tenantID: tenantID) {
            throw HermesGatewayApplyError.alreadyRunning
        }
        let jobID = UUID()
        let initialSteps = Self.pipeline.map { HermesGatewayApplyStep(id: $0, state: .pending) }
        let row = HermesGatewayApplyJob(
            id: jobID,
            tenantID: tenantID,
            state: .running,
            steps: initialSteps
        )
        try await row.create(on: fluent.db())

        runningTasks[tenantID] = Task { [weak self] in
            await self?.execute(jobID: jobID, tenantID: tenantID)
            await self?.clearRunningTask(tenantID: tenantID)
        }
        return row.snapshot()
    }

    /// Most recent non-terminal job for the tenant, else the most recent job
    /// overall. Backs the client's reconnect-on-launch.
    func currentJob(tenantID: UUID) async throws -> HermesGatewayApplyJobStatus? {
        if let running = try await HermesGatewayApplyJob.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$state == HermesGatewayApplyJobState.running.rawValue)
            .sort(\.$createdAt, .descending)
            .first()
        {
            return running.snapshot()
        }
        return try await HermesGatewayApplyJob.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .sort(\.$createdAt, .descending)
            .first()?
            .snapshot()
    }

    /// Tenant-scoped job lookup (prevents cross-tenant reads).
    func job(id: UUID, tenantID: UUID) async throws -> HermesGatewayApplyJobStatus? {
        try await loadRow(jobID: id, tenantID: tenantID)?.snapshot()
    }

    /// Subscribe to live progress. Replays the current step states as `.step`
    /// events, then streams subsequent transitions. If the job is already
    /// terminal, emits `.done` and finishes immediately.
    func subscribe(jobID: UUID, tenantID: UUID) -> AsyncThrowingStream<HermesGatewayApplyEvent, Error> {
        AsyncThrowingStream { continuation in
            let subID = UUID()
            Task {
                guard let row = try? await self.loadRow(jobID: jobID, tenantID: tenantID) else {
                    continuation.finish(throwing: HermesGatewayApplyShim.notFound)
                    return
                }
                let snapshot = row.snapshot()
                for step in snapshot.steps {
                    continuation.yield(.step(step))
                }
                if snapshot.state != .running {
                    continuation.yield(.done(snapshot))
                    continuation.finish()
                    return
                }
                await self.registerSubscriber(jobID: jobID, subID: subID, continuation: continuation)
                continuation.onTermination = { _ in
                    Task { await self.removeSubscriber(jobID: jobID, subID: subID) }
                }
            }
        }
    }

    // MARK: - Subscriber registry

    private func registerSubscriber(
        jobID: UUID,
        subID: UUID,
        continuation: AsyncThrowingStream<HermesGatewayApplyEvent, Error>.Continuation
    ) {
        subscribers[jobID, default: [:]][subID] = continuation
    }

    private func removeSubscriber(jobID: UUID, subID: UUID) {
        subscribers[jobID]?[subID] = nil
        if subscribers[jobID]?.isEmpty == true {
            subscribers[jobID] = nil
        }
    }

    private func broadcast(_ event: HermesGatewayApplyEvent, jobID: UUID) {
        guard let conts = subscribers[jobID] else { return }
        for cont in conts.values {
            cont.yield(event)
        }
    }

    private func finishSubscribers(jobID: UUID, with snapshot: HermesGatewayApplyJobStatus) {
        guard let conts = subscribers[jobID] else { return }
        for cont in conts.values {
            cont.yield(.done(snapshot))
            cont.finish()
        }
        subscribers[jobID] = nil
    }

    private func clearRunningTask(tenantID: UUID) {
        runningTasks[tenantID] = nil
    }

    // MARK: - Step engine

    private func execute(jobID: UUID, tenantID: UUID) async {
        do {
            // writeEnv — seed the tenant's config.yaml + .env from saved gateways.
            try await mark(jobID, .writeEnv, .running)
            if let written = try await containerManager.seedGatewayConfig(tenantID: tenantID) {
                try await mark(jobID, .writeEnv, .succeeded, detail: "wrote \(written) gateway variable(s)")
            } else {
                try await mark(jobID, .writeEnv, .skipped, detail: "no container yet — will seed on launch")
            }

            // restartContainer — rm -f + docker run (re-seeds) so the new .env applies.
            try await mark(jobID, .restartContainer, .running)
            try await containerManager.applyGatewayConfig(tenantID: tenantID)
            try await mark(jobID, .restartContainer, .succeeded)

            // healthCheck — poll the freshly-started container's OpenAI gateway.
            try await mark(jobID, .healthCheck, .running)
            guard let handle = try await containerManager.handle(tenantID: tenantID) else {
                try await mark(jobID, .healthCheck, .failed, detail: "container did not start")
                await markGatewayRows(tenantID: tenantID, verified: false, code: "no_container")
                await finalize(jobID, state: .failed, errorMessage: "Your assistant didn't start. Please try again.")
                return
            }
            let healthy = await awaitHealthy(port: handle.port, apiKey: handle.apiServerKey)
            guard healthy else {
                try await mark(jobID, .healthCheck, .failed, detail: "gateway didn't respond in time")
                await markGatewayRows(tenantID: tenantID, verified: false, code: "unhealthy")
                await finalize(
                    jobID,
                    state: .failed,
                    errorMessage: "Your assistant restarted but didn't respond in time. Double-check your tokens and try again."
                )
                return
            }
            try await mark(jobID, .healthCheck, .succeeded)
            await markGatewayRows(tenantID: tenantID, verified: true, code: nil)
            await finalize(jobID, state: .succeeded, errorMessage: nil)
        } catch {
            logger.error("hermes gateway apply failed", metadata: [
                "jobID": "\(jobID)", "tenantID": "\(tenantID)", "error": "\(error)",
            ])
            await markActiveStepFailed(jobID: jobID, error: error)
            await markGatewayRows(tenantID: tenantID, verified: false, code: "apply_failed")
            await finalize(jobID, state: .failed, errorMessage: "Applying your gateway settings failed: \(error)")
        }
    }

    /// Poll the health probe every 2s until healthy or the timeout elapses.
    private func awaitHealthy(port: Int, apiKey: String) async -> Bool {
        let deadline = now().addingTimeInterval(TimeInterval(healthTimeoutSeconds))
        while now() < deadline {
            if await healthProbe(port, apiKey) {
                return true
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return await healthProbe(port, apiKey)
    }

    /// Stamp the tenant's configured gateway rows after an apply: `verified` +
    /// `verified_at` on success, `error` + `last_failure_*` on failure.
    private func markGatewayRows(tenantID: UUID, verified: Bool, code: String?) async {
        guard let rows = try? await UserHermesGateway.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .all()
        else { return }
        let ts = now()
        for row in rows {
            if verified {
                row.status = HermesGatewayStatus.verified.rawValue
                row.verifiedAt = ts
                row.lastFailureAt = nil
                row.lastFailureCode = nil
            } else {
                row.status = HermesGatewayStatus.error.rawValue
                row.lastFailureAt = ts
                row.lastFailureCode = code
            }
            try? await row.update(on: fluent.db())
        }
    }

    private func mark(
        _ jobID: UUID,
        _ id: HermesGatewayApplyStepID,
        _ state: HermesGatewayApplyStepState,
        detail: String? = nil
    ) async throws {
        guard let row = try await loadRowAny(jobID: jobID) else { return }
        var steps = row.steps
        let ts = now()
        if let idx = steps.firstIndex(where: { $0.id == id }) {
            let prior = steps[idx]
            steps[idx] = HermesGatewayApplyStep(
                id: id,
                state: state,
                detail: detail ?? prior.detail,
                startedAt: state == .running ? ts : prior.startedAt,
                finishedAt: (state == .succeeded || state == .failed || state == .skipped) ? ts : prior.finishedAt
            )
        }
        row.stepsJSON = HermesGatewayApplyJob.encodeSteps(steps)
        try await row.update(on: fluent.db())
        if let updated = steps.first(where: { $0.id == id }) {
            broadcast(.step(updated), jobID: jobID)
        }
    }

    private func markActiveStepFailed(jobID: UUID, error: any Error) async {
        guard let row = try? await loadRowAny(jobID: jobID) else { return }
        if let active = row.steps.first(where: { $0.state == .running })?.id
            ?? row.steps.first(where: { $0.state == .pending })?.id
        {
            try? await mark(jobID, active, .failed, detail: "\(error)")
        }
    }

    private func finalize(_ jobID: UUID, state: HermesGatewayApplyJobState, errorMessage: String?) async {
        guard let row = try? await loadRowAny(jobID: jobID) else { return }
        row.state = state.rawValue
        row.errorMessage = errorMessage
        try? await row.update(on: fluent.db())
        broadcast(.status(state), jobID: jobID)
        finishSubscribers(jobID: jobID, with: row.snapshot())
    }

    // MARK: - Private helpers

    private func hasRunningJob(tenantID: UUID) async throws -> Bool {
        try await HermesGatewayApplyJob.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$state == HermesGatewayApplyJobState.running.rawValue)
            .first() != nil
    }

    private func loadRow(jobID: UUID, tenantID: UUID) async throws -> HermesGatewayApplyJob? {
        try await HermesGatewayApplyJob.query(on: fluent.db())
            .filter(\.$id == jobID)
            .filter(\.$tenantID == tenantID)
            .first()
    }

    /// Job lookup without the tenant filter — used only by the internal step
    /// engine, which already operates on a job it created for the tenant.
    private func loadRowAny(jobID: UUID) async throws -> HermesGatewayApplyJob? {
        try await HermesGatewayApplyJob.find(jobID, on: fluent.db())
    }
}

/// Minimal `Error` used when a subscribed job id doesn't exist for the tenant.
enum HermesGatewayApplyShim: Error { case notFound }
