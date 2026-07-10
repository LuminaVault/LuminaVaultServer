import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import ServiceLifecycle

/// Replica-safe schedule dispatcher. Every due minute receives a stable key;
/// the partial unique index from M93 elects exactly one writer even when
/// multiple application replicas evaluate the same cron expression.
actor WorkflowScheduler: Service {
    private let fluent: Fluent
    private let logger: Logger
    private let tickInterval: Duration

    init(fluent: Fluent, logger: Logger, tickInterval: Duration = .seconds(60)) {
        self.fluent = fluent
        self.logger = logger
        self.tickInterval = tickInterval
    }

    func run() async throws {
        logger.info("workflow.scheduler started")
        while !Task.isCancelled {
            do { _ = try await tick(at: Date()) }
            catch { logger.warning("workflow.scheduler tick failed: \(error)") }
            try? await Task.sleep(for: tickInterval)
        }
    }

    @discardableResult
    func tick(at now: Date) async throws -> Int {
        let workflows = try await Workflow.query(on: fluent.db())
            .filter(\.$enabled == true)
            .filter(\.$publishedVersionID != nil)
            .all()
        var enqueued = 0
        for workflow in workflows where workflow.draftDefinition.trigger == .schedule {
            let config = workflow.draftDefinition.triggerConfiguration
            guard let rawCron = config["cron"], let cron = try? CronExpression(rawCron) else { continue }
            let timezone = TimeZone(identifier: config["timezone"] ?? "UTC") ?? .gmt
            guard cron.matches(now, in: timezone), let versionID = workflow.publishedVersionID else { continue }
            let workflowID = try workflow.requireID()
            let key = dedupeKey(workflowID: workflowID, date: now)
            let existing = try await WorkflowRun.query(on: fluent.db())
                .filter(\.$workflowID == workflowID)
                .filter(\.$dedupeKey == key)
                .first()
            guard existing == nil else { continue }
            let run = WorkflowRun()
            run.id = UUID(); run.tenantID = workflow.tenantID
            run.workflowID = workflowID; run.versionID = versionID
            run.status = WorkflowRunStatus.queued.rawValue
            run.triggerKind = WorkflowTriggerKind.schedule.rawValue
            run.input = ["scheduledAt": ISO8601DateFormatter().string(from: now)]
            run.dedupeKey = key
            do {
                try await run.create(on: fluent.db())
                enqueued += 1
            } catch {
                // A competing replica may have won the unique key race.
                logger.debug("workflow.schedule duplicate suppressed: \(key)")
            }
        }
        return enqueued
    }

    private func dedupeKey(workflowID: UUID, date: Date) -> String {
        String(format: "schedule:%@:%lld", workflowID.uuidString, Int64(date.timeIntervalSince1970) / 60)
    }
}
