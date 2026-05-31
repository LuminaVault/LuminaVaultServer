import FluentKit
import Foundation
import HummingbirdFluent
import LuminaVaultShared
import Logging

/// HER-330 — orchestrates the owner-triggered "Update Hermes" flow.
///
/// Runs as a single-flight, detached, blue-green update over the central
/// Hermes container (`CentralHermesManager`) followed by a tenant
/// reprovision (`HermesContainerManager.reprovisionAll`). Job state is
/// persisted to `hermes_update_jobs` on every step transition so the iOS
/// client can reconnect and the server can restart without losing the
/// snapshot. Progress is broadcast to any number of SSE subscribers.
///
/// Concurrency: `actor` isolation serialises all state + DB writes. The job
/// body runs in a task **owned by this actor** (`runningTask`) — not
/// `Task.detached` — so it inherits the actor's executor and can be
/// cancelled via the stored handle. The request handler returns immediately
/// after `startUpdate` kicks it off; the persisted row is the source of truth.
actor HermesUpdateService {
    private let fluent: Fluent
    private let central: CentralHermesManager
    private let containerManager: HermesContainerManager?
    private let healthTimeoutSeconds: Int
    private let logger: Logger
    private let now: @Sendable () -> Date

    private var runningTask: Task<Void, Never>?
    /// jobID → (subscriberID → continuation). Live SSE fan-out.
    private var subscribers: [UUID: [UUID: AsyncThrowingStream<HermesUpdateEvent, Error>.Continuation]] = [:]

    /// Full pipeline, in execution order. `rollback` is appended/driven only
    /// on the failure path.
    private static let pipeline: [HermesUpdateStepID] = [
        .preflight, .pullImage, .verifyImage, .snapshotCurrent,
        .swapCentral, .healthCheckCentral, .reprovisionTenants,
        .verifyTenants, .promote,
    ]

    init(
        fluent: Fluent,
        central: CentralHermesManager,
        containerManager: HermesContainerManager?,
        healthTimeoutSeconds: Int = 90,
        logger: Logger,
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.fluent = fluent
        self.central = central
        self.containerManager = containerManager
        self.healthTimeoutSeconds = healthTimeoutSeconds
        self.logger = logger
        self.now = now
    }

    // MARK: - Public API

    /// Start an update. Throws `HermesUpdateError.alreadyRunning` if a job is
    /// already in flight (single-flight guard). Returns the initial snapshot.
    func startUpdate(targetTag: String?) async throws -> HermesUpdateJobStatus {
        if try await hasRunningJob() {
            throw HermesUpdateError.alreadyRunning
        }
        let tag = (targetTag?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? central.config.defaultChannelTag
        let targetRef = central.fullRef(tag: tag)
        let currentRef = await central.currentImageRef()

        let jobID = UUID()
        let initialSteps = Self.pipeline.map { HermesUpdateStep(id: $0, state: .pending) }
        let row = HermesUpdateJob(
            id: jobID,
            state: .running,
            steps: initialSteps,
            fromVersion: currentRef,
            toVersion: targetRef,
        )
        try await row.create(on: fluent.db())

        runningTask = Task { [weak self] in
            await self?.execute(jobID: jobID, targetRef: targetRef, previousRef: currentRef)
        }
        return row.snapshot()
    }

    /// Trigger a rollback for a previously-failed job: launches a new job that
    /// restores the central container to the failed job's `fromVersion` and
    /// reprovisions tenants onto it. Returns the new job's snapshot.
    func startRollback(forJobID failedJobID: UUID) async throws -> HermesUpdateJobStatus {
        if try await hasRunningJob() {
            throw HermesUpdateError.alreadyRunning
        }
        guard let failed = try await loadRow(jobID: failedJobID),
              let restoreRef = failed.fromVersion
        else { throw HermesUpdateError.rollbackFailed("no recorded previous version") }

        let jobID = UUID()
        let steps = [HermesUpdateStep(id: .rollback, state: .pending)]
        let row = HermesUpdateJob(
            id: jobID,
            state: .running,
            steps: steps,
            fromVersion: failed.toVersion,
            toVersion: restoreRef,
        )
        try await row.create(on: fluent.db())

        runningTask = Task { [weak self] in
            await self?.executeManualRollback(jobID: jobID, restoreRef: restoreRef)
        }
        return row.snapshot()
    }

    /// Most recent non-terminal job, else the most recent job overall. Backs
    /// the client's reconnect-on-launch.
    func currentJob() async throws -> HermesUpdateJobStatus? {
        if let running = try await HermesUpdateJob.query(on: fluent.db())
            .filter(\.$state == HermesUpdateJobState.running.rawValue)
            .sort(\.$createdAt, .descending)
            .first()
        {
            return running.snapshot()
        }
        return try await HermesUpdateJob.query(on: fluent.db())
            .sort(\.$createdAt, .descending)
            .first()?
            .snapshot()
    }

    func job(id: UUID) async throws -> HermesUpdateJobStatus? {
        try await loadRow(jobID: id)?.snapshot()
    }

    /// HER-330 — bulk-reprovision every per-tenant Hermes container onto the
    /// current per-tenant image WITHOUT running a full central-update job.
    /// Force-removes then re-creates each tenant container (re-seeding
    /// `config.yaml`); the per-tenant data volume is bind-mounted and
    /// untouched, so no memory is lost. Idempotent. Returns the count
    /// reprovisioned. Throws `HermesUpdateError.perTenantDisabled` when
    /// per-tenant containers are turned off.
    func reprovisionTenants() async throws -> Int {
        guard let cm = containerManager else {
            throw HermesUpdateError.perTenantDisabled
        }
        return try await cm.reprovisionAll()
    }

    func currentVersionInfo() async -> HermesVersionInfo {
        let ref = await central.currentImageRef() ?? central.fullRef(tag: central.config.defaultChannelTag)
        let digest = await central.currentImageDigest()
        let label = Self.shortLabel(ref: ref, digest: digest)
        let lastUpdated = try? await HermesUpdateJob.query(on: fluent.db())
            .filter(\.$state == HermesUpdateJobState.succeeded.rawValue)
            .sort(\.$updatedAt, .descending)
            .first()?
            .updatedAt
        return HermesVersionInfo(
            currentRef: ref,
            currentDigest: digest,
            currentLabel: label,
            availableLabel: nil,
            updateAvailable: false,
            lastUpdatedAt: lastUpdated ?? nil,
        )
    }

    /// Subscribe to live progress. Replays the current step states as `.step`
    /// events, then streams subsequent transitions. If the job is already
    /// terminal, emits `.done` and finishes immediately.
    func subscribe(jobID: UUID) -> AsyncThrowingStream<HermesUpdateEvent, Error> {
        AsyncThrowingStream { continuation in
            let subID = UUID()
            Task {
                guard let row = try? await self.loadRow(jobID: jobID) else {
                    continuation.finish(throwing: HTTPErrorShim.notFound)
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
        continuation: AsyncThrowingStream<HermesUpdateEvent, Error>.Continuation,
    ) {
        subscribers[jobID, default: [:]][subID] = continuation
    }

    private func removeSubscriber(jobID: UUID, subID: UUID) {
        subscribers[jobID]?[subID] = nil
        if subscribers[jobID]?.isEmpty == true { subscribers[jobID] = nil }
    }

    private func broadcast(_ event: HermesUpdateEvent, jobID: UUID) {
        guard let conts = subscribers[jobID] else { return }
        for cont in conts.values { cont.yield(event) }
    }

    private func finishSubscribers(jobID: UUID, with snapshot: HermesUpdateJobStatus) {
        guard let conts = subscribers[jobID] else { return }
        for cont in conts.values {
            cont.yield(.done(snapshot))
            cont.finish()
        }
        subscribers[jobID] = nil
    }

    // MARK: - Step engine

    private func execute(jobID: UUID, targetRef: String, previousRef: String?) async {
        var swapStarted = false
        var oldRemoved = false
        do {
            // preflight
            try await step(jobID, .preflight) {
                try await self.central.assertDockerReachable()
                return self.central.config.containerName
            }
            let previousDigest = await central.currentImageDigest()

            // pullImage
            try await step(jobID, .pullImage) {
                try await self.central.pull(ref: targetRef)
                return targetRef
            }

            // verifyImage — short-circuit if the pulled digest matches current.
            let newDigest = await central.imageDigest(ref: targetRef)
            if let nd = newDigest, let pd = previousDigest, nd == pd {
                try await mark(jobID, .verifyImage, .succeeded, detail: "already up to date")
                try await skipRemaining(jobID, from: .snapshotCurrent)
                await finalize(jobID, state: .succeeded, errorMessage: nil)
                return
            }
            try await mark(jobID, .verifyImage, .succeeded, detail: newDigest ?? targetRef)

            // snapshotCurrent — rollback pointer already persisted as fromVersion.
            try await mark(jobID, .snapshotCurrent, .succeeded, detail: previousRef ?? "none")

            // swapCentral — launch new image on temp name/port; old keeps serving.
            try await mark(jobID, .swapCentral, .running)
            swapStarted = true
            try await central.runTemp(image: targetRef)
            try await mark(jobID, .swapCentral, .succeeded)

            // healthCheckCentral
            try await mark(jobID, .healthCheckCentral, .running)
            let tempHealthy = await central.awaitTempHealthy(timeoutSeconds: healthTimeoutSeconds)
            guard tempHealthy else {
                // Old container never touched — remove temp, no downtime.
                await central.removeTemp()
                try await mark(jobID, .healthCheckCentral, .failed, detail: "new version didn't respond in time")
                await finalize(
                    jobID,
                    state: .rolledBack,
                    errorMessage: "The new version started but didn't respond in time. The previous version is still running.",
                )
                return
            }
            // Cutover: remove old + temp, run new on canonical name/port.
            try await central.promoteTempToCanonical(image: targetRef)
            oldRemoved = true
            let canonicalHealthy = await central.awaitCanonicalHealthy(timeoutSeconds: healthTimeoutSeconds)
            guard canonicalHealthy else {
                try await mark(jobID, .healthCheckCentral, .failed, detail: "cutover container unhealthy")
                await rollbackToPrevious(jobID: jobID, restoreRef: previousRef)
                return
            }
            try await mark(jobID, .healthCheckCentral, .succeeded)

            // reprovisionTenants
            try await mark(jobID, .reprovisionTenants, .running)
            if let cm = containerManager {
                await cm.setImage(targetRef)
                let count = (try? await cm.reprovisionAll()) ?? 0
                try await mark(jobID, .reprovisionTenants, .succeeded, detail: "\(count) tenant container(s) updated")
            } else {
                try await mark(jobID, .reprovisionTenants, .skipped, detail: "per-tenant containers disabled")
            }

            // verifyTenants (best-effort)
            try await mark(jobID, .verifyTenants, .succeeded, detail: "ok")

            // promote
            try await mark(jobID, .promote, .succeeded, detail: targetRef)

            await finalize(jobID, state: .succeeded, errorMessage: nil)
        } catch {
            logger.error("hermes update failed", metadata: ["jobID": "\(jobID)", "error": "\(error)"])
            await markActiveStepFailed(jobID: jobID, error: error)
            if swapStarted, oldRemoved {
                await rollbackToPrevious(jobID: jobID, restoreRef: previousRef)
            } else if swapStarted {
                await central.removeTemp()
                await finalize(
                    jobID,
                    state: .rolledBack,
                    errorMessage: Self.userMessage(for: error) + " The previous version is still running.",
                )
            } else {
                await finalize(jobID, state: .failed, errorMessage: Self.userMessage(for: error))
            }
        }
    }

    /// Auto-rollback after the old container was already removed: restore the
    /// previous image on the canonical name and reprovision tenants back.
    private func rollbackToPrevious(jobID: UUID, restoreRef: String?) async {
        guard let restoreRef else {
            await finalize(jobID, state: .failed, errorMessage: "Update failed and no previous version was recorded to restore. Manual recovery required.")
            return
        }
        do {
            try await addOrMark(jobID, .rollback, .running, detail: "restoring \(restoreRef)")
            try await central.restoreCanonical(image: restoreRef)
            let healthy = await central.awaitCanonicalHealthy(timeoutSeconds: healthTimeoutSeconds)
            guard healthy else { throw HermesUpdateError.rollbackFailed("restored container unhealthy") }
            if let cm = containerManager {
                await cm.setImage(restoreRef)
                _ = try? await cm.reprovisionAll()
            }
            try await addOrMark(jobID, .rollback, .succeeded, detail: "restored \(restoreRef)")
            await finalize(
                jobID,
                state: .rolledBack,
                errorMessage: "The update didn't complete, so the previous version was restored.",
            )
        } catch {
            try? await addOrMark(jobID, .rollback, .failed, detail: "\(error)")
            await finalize(
                jobID,
                state: .failed,
                errorMessage: "The update failed and automatic restore did not succeed. Your assistant may be offline — manual recovery required.",
            )
        }
    }

    /// Manual rollback job body (single `rollback` step).
    private func executeManualRollback(jobID: UUID, restoreRef: String) async {
        do {
            try await mark(jobID, .rollback, .running, detail: "restoring \(restoreRef)")
            try await central.restoreCanonical(image: restoreRef)
            let healthy = await central.awaitCanonicalHealthy(timeoutSeconds: healthTimeoutSeconds)
            guard healthy else { throw HermesUpdateError.rollbackFailed("restored container unhealthy") }
            if let cm = containerManager {
                await cm.setImage(restoreRef)
                _ = try? await cm.reprovisionAll()
            }
            try await mark(jobID, .rollback, .succeeded, detail: "restored \(restoreRef)")
            await finalize(jobID, state: .rolledBack, errorMessage: nil)
        } catch {
            try? await mark(jobID, .rollback, .failed, detail: "\(error)")
            await finalize(jobID, state: .failed, errorMessage: "Restore did not succeed. Manual recovery may be required.")
        }
    }

    // MARK: - Step helpers

    /// Run `work` for `id`: mark running, run, mark succeeded with the returned
    /// detail. Rethrows so the caller's catch can drive rollback.
    private func step(
        _ jobID: UUID,
        _ id: HermesUpdateStepID,
        _ work: () async throws -> String?,
    ) async throws {
        try await mark(jobID, id, .running)
        let detail = try await work()
        try await mark(jobID, id, .succeeded, detail: detail)
    }

    private func mark(
        _ jobID: UUID,
        _ id: HermesUpdateStepID,
        _ state: HermesUpdateStepState,
        detail: String? = nil,
    ) async throws {
        guard let row = try await loadRow(jobID: jobID) else { return }
        var steps = row.steps
        let ts = now()
        if let idx = steps.firstIndex(where: { $0.id == id }) {
            let prior = steps[idx]
            steps[idx] = HermesUpdateStep(
                id: id,
                state: state,
                detail: detail ?? prior.detail,
                startedAt: state == .running ? ts : prior.startedAt,
                finishedAt: (state == .succeeded || state == .failed || state == .skipped) ? ts : prior.finishedAt,
            )
        }
        row.stepsJSON = HermesUpdateJob.encodeSteps(steps)
        try await row.update(on: fluent.db())
        if let updated = steps.first(where: { $0.id == id }) {
            broadcast(.step(updated), jobID: jobID)
        }
    }

    /// Like `mark`, but appends the step if the job's step list doesn't have
    /// it yet (used for `rollback`, which isn't in the initial pipeline).
    private func addOrMark(
        _ jobID: UUID,
        _ id: HermesUpdateStepID,
        _ state: HermesUpdateStepState,
        detail: String? = nil,
    ) async throws {
        guard let row = try await loadRow(jobID: jobID) else { return }
        var steps = row.steps
        if !steps.contains(where: { $0.id == id }) {
            steps.append(HermesUpdateStep(id: id, state: .pending))
            row.stepsJSON = HermesUpdateJob.encodeSteps(steps)
            try await row.update(on: fluent.db())
        }
        try await mark(jobID, id, state, detail: detail)
    }

    private func skipRemaining(_ jobID: UUID, from: HermesUpdateStepID) async throws {
        guard let fromIdx = Self.pipeline.firstIndex(of: from) else { return }
        for id in Self.pipeline[fromIdx...] {
            try await mark(jobID, id, .skipped)
        }
    }

    private func markActiveStepFailed(jobID: UUID, error: any Error) async {
        guard let row = try? await loadRow(jobID: jobID) else { return }
        // The first non-terminal (running/pending) step is the one that broke.
        if let active = row.steps.first(where: { $0.state == .running })?.id
            ?? row.steps.first(where: { $0.state == .pending })?.id
        {
            try? await mark(jobID, active, .failed, detail: Self.userMessage(for: error))
        }
    }

    private func finalize(_ jobID: UUID, state: HermesUpdateJobState, errorMessage: String?) async {
        guard let row = try? await loadRow(jobID: jobID) else { return }
        row.state = state.rawValue
        row.errorMessage = errorMessage
        try? await row.update(on: fluent.db())
        broadcast(.status(state), jobID: jobID)
        finishSubscribers(jobID: jobID, with: row.snapshot())
    }

    // MARK: - Private helpers

    private func hasRunningJob() async throws -> Bool {
        try await HermesUpdateJob.query(on: fluent.db())
            .filter(\.$state == HermesUpdateJobState.running.rawValue)
            .first() != nil
    }

    private func loadRow(jobID: UUID) async throws -> HermesUpdateJob? {
        try await HermesUpdateJob.find(jobID, on: fluent.db())
    }

    private static func shortLabel(ref: String, digest: String?) -> String {
        if let tag = ref.split(separator: ":").last, ref.contains(":") {
            return String(tag)
        }
        if let digest, let short = digest.split(separator: ":").last {
            return "sha256:" + short.prefix(12)
        }
        return ref
    }

    /// Human-readable mapping for common failure causes (surfaced verbatim to
    /// the iOS client as `errorMessage` / step detail).
    static func userMessage(for error: any Error) -> String {
        switch error {
        case HermesUpdateError.dockerUnreachable:
            return "Couldn't reach Docker on the server."
        case let HermesUpdateError.pullFailed(stderr, _):
            if stderr.lowercased().contains("unauthorized") || stderr.lowercased().contains("denied") {
                return "The server isn't authorized to download Hermes. Check the registry credentials."
            }
            return "Couldn't download the new version. Check the server's internet connection and try again."
        case HermesUpdateError.containerRunFailed:
            return "The new version failed to start."
        case HermesUpdateError.healthCheckTimedOut:
            return "The new version started but didn't respond in time."
        case HermesUpdateError.alreadyRunning:
            return "An update is already in progress."
        default:
            return "The update failed: \(error)"
        }
    }
}

/// Minimal `Error` used when a subscribed job id doesn't exist. Kept local so
/// the service doesn't import Hummingbird just for one throw.
enum HTTPErrorShim: Error { case notFound }
