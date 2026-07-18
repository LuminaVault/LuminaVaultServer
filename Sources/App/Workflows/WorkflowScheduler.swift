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
    private let workflowService: WorkflowService
    private let logger: Logger
    private let tickInterval: Duration

    init(fluent: Fluent, workflowService: WorkflowService, logger: Logger, tickInterval: Duration = .seconds(60)) {
        self.fluent = fluent
        self.workflowService = workflowService
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
        for workflow in workflows {
            guard let versionID = workflow.publishedVersionID,
                  let version = try await WorkflowVersion.find(versionID, on: fluent.db()),
                  version.definition.trigger == .schedule
            else { continue }
            let config = version.definition.triggerConfiguration
            let isOneShotDue = config["runAt"].flatMap(ISO8601DateFormatter().date(from:)).map { now >= $0 } ?? false
            let isCronDue: Bool
            if let rawCron = config["cron"], let cron = try? CronExpression(rawCron) {
                let timezone = TimeZone(identifier: config["timezone"] ?? "UTC") ?? .gmt
                isCronDue = cron.matches(now, in: timezone)
            } else {
                isCronDue = false
            }
            guard isOneShotDue || isCronDue else { continue }
            let workflowID = try workflow.requireID()
            let key = dedupeKey(workflowID: workflowID, date: now)
            let existing = try await WorkflowRun.query(on: fluent.db())
                .filter(\.$workflowID == workflowID)
                .filter(\.$dedupeKey == key)
                .first()
            guard existing == nil else { continue }
            do {
                _ = try await workflowService.enqueue(
                    tenantID: workflow.tenantID,
                    workflowID: workflowID,
                    trigger: .schedule,
                    request: WorkflowRunRequest(input: ["scheduledAt": ISO8601DateFormatter().string(from: now)]),
                    dedupeKey: key
                )
                enqueued += 1
                if isOneShotDue {
                    workflow.enabled = false
                    try await workflow.save(on: fluent.db())
                }
            } catch WorkflowServiceError.activeRunLimit {
                logger.info("workflow.schedule deferred by active-run limit: \(workflowID)")
            } catch WorkflowServiceError.forbidden {
                logger.info("workflow.schedule skipped for inactive entitlement: \(workflowID)")
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
