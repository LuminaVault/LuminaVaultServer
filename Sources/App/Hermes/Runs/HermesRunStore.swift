import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared

/// Persistence for Hermes runs shared by the service actor and the per-run
/// watchers. Every event append bumps `hermes_runs.last_seq` in the same
/// write so `lastSeq` on the DTO is always the resume cursor, and every
/// change is published on the `EventBus` for live SSE fan-out.
struct HermesRunStore: Sendable {
    let fluent: Fluent
    let eventBus: EventBus
    let logger: Logger
    let now: @Sendable () -> Date

    init(fluent: Fluent, eventBus: EventBus, logger: Logger, now: @escaping @Sendable () -> Date = Date.init) {
        self.fluent = fluent
        self.eventBus = eventBus
        self.logger = logger
        self.now = now
    }

    func find(tenantID: UUID, runID: UUID) async throws -> HermesRun? {
        try await HermesRun.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == runID)
            .first()
    }

    func find(runID: UUID) async throws -> HermesRun? {
        try await HermesRun.find(runID, on: fluent.db())
    }

    func list(tenantID: UUID, limit: Int) async throws -> [HermesRun] {
        try await HermesRun.query(on: fluent.db(), tenantID: tenantID)
            .sort(\.$startedAt, .descending)
            .limit(limit)
            .all()
    }

    /// Non-terminal rows, oldest first — the watcher re-attach set.
    func activeRuns() async throws -> [HermesRun] {
        try await HermesRun.query(on: fluent.db())
            .filter(\.$status ~~ [HermesRunStatus.queued, .running, .waitingForApproval].map(\.rawValue))
            .sort(\.$startedAt, .ascending)
            .all()
    }

    func events(runID: UUID, afterSeq: Int, limit: Int) async throws -> [HermesRunEventRow] {
        try await HermesRunEventRow.query(on: fluent.db())
            .filter(\.$runID == runID)
            .filter(\.$seq > afterSeq)
            .sort(\.$seq, .ascending)
            .limit(limit)
            .all()
    }

    /// Append one event and apply `mutate` to the run row in the same
    /// logical step. Returns the new `seq`, or nil when the run row is gone
    /// (tenant deleted mid-run — the watcher should stop).
    @discardableResult
    func append(
        runID: UUID,
        name: String,
        payload: AnyJSONValue,
        at: Date,
        mutate: (HermesRun) -> Void
    ) async throws -> (seq: Int, run: HermesRun)? {
        let db = fluent.db()
        guard let run = try await HermesRun.find(runID, on: db) else { return nil }
        let seq = run.lastSeq + 1
        try await HermesRunEventRow(runID: runID, seq: seq, event: name, payload: payload, at: at).save(on: db)
        run.lastSeq = seq
        run.lastEvent = name
        mutate(run)
        try await run.save(on: db)
        publish(run: run, seq: seq, event: name)
        return (seq, run)
    }

    /// Request-path mutation that must not race the watcher's full-row
    /// saves: only the named columns are written.
    func clearPendingApproval(runID: UUID) async throws {
        try await HermesRun.query(on: fluent.db())
            .filter(\.$id == runID)
            .set(\.$pendingApproval, to: nil)
            .set(\.$status, to: HermesRunStatus.running.rawValue)
            .update()
    }

    /// Terminal transition without a Hermes event behind it (`lost` after a
    /// restart, `stopped` when Hermes already forgot the run). Persists a
    /// synthetic `watcher.<status>` event so SSE consumers see the end.
    func finish(runID: UUID, status: HermesRunStatus, error: String?) async throws -> HermesRun? {
        let finishedAt = now()
        let payload: AnyJSONValue = .object([
            "status": .string(status.rawValue),
            "error": error.map { .string($0) } ?? .null,
        ])
        return try await append(runID: runID, name: "watcher.\(status.rawValue)", payload: payload, at: finishedAt) { run in
            run.runStatus = status
            run.pendingApproval = nil
            run.finishedAt = finishedAt
            if let error {
                run.error = error
            }
        }?.run
    }

    func publish(run: HermesRun, seq: Int, event: String) {
        guard let id = run.id else { return }
        eventBus.publish(
            HermesRunEventPayload(runID: id, seq: seq, event: event, status: run.status)
                .skillEvent(tenantID: run.tenantID)
        )
    }
}
