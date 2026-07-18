import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import ServiceLifecycle

/// Expires abandoned approvals and removes payload snapshots after the
/// documented 30-day debugging window. Run metadata remains for history.
actor WorkflowMaintenanceService: Service {
    private let fluent: Fluent
    private let logger: Logger
    private let events: WorkflowEventStore?
    private let interval: Duration

    init(fluent: Fluent, events: WorkflowEventStore? = nil, logger: Logger, interval: Duration = .seconds(3600)) {
        self.fluent = fluent; self.events = events; self.logger = logger; self.interval = interval
    }

    func run() async throws {
        while !Task.isCancelled {
            do { try await tick(at: Date()) }
            catch { logger.warning("workflow.maintenance failed: \(error)") }
            try? await Task.sleep(for: interval)
        }
    }

    func tick(at now: Date) async throws {
        let expired = try await WorkflowApproval.query(on: fluent.db())
            .filter(\.$status == "pending").filter(\.$expiresAt < now).all()
        for approval in expired {
            approval.status = "expired"
            try await approval.save(on: fluent.db())
            if let run = try await WorkflowRun.find(approval.runID, on: fluent.db()),
               run.status == WorkflowRunStatus.waitingForApproval.rawValue
            {
                run.status = WorkflowRunStatus.timedOut.rawValue
                run.errorMessage = "Approval expired"; run.endedAt = now
                try await run.save(on: fluent.db())
            }
        }
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        await events?.prune(before: cutoff)
        let old = try await WorkflowNodeRun.query(on: fluent.db()).filter(\.$createdAt < cutoff).all()
        for node in old where node.inputSnapshot != nil || node.outputSnapshot != nil {
            node.inputSnapshot = nil; node.outputSnapshot = nil
            try await node.save(on: fluent.db())
        }
    }
}
