import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import ServiceLifecycle

/// Idempotently promotes legacy scheduled Jobs into versioned workflows.
/// The original `skills_state` row remains as a compatibility facade, but its
/// workflow link makes CronScheduler stop dispatching it directly.
actor LegacyJobWorkflowMigrator: Service {
    private let fluent: Fluent
    private let catalog: SkillCatalog
    private let logger: Logger
    private let interval: Duration

    init(fluent: Fluent, catalog: SkillCatalog, logger: Logger, interval: Duration = .seconds(300)) {
        self.fluent = fluent; self.catalog = catalog; self.logger = logger; self.interval = interval
    }

    func run() async throws {
        while !Task.isCancelled {
            do { _ = try await migrate() }
            catch { logger.warning("workflow legacy migration failed: \(error)") }
            try? await Task.sleep(for: interval)
        }
    }

    @discardableResult
    func migrate() async throws -> Int {
        let users = try await User.query(on: fluent.db()).all()
        var count = 0
        for user in users {
            let tenantID = try user.requireID()
            for manifest in try await catalog.manifests(for: tenantID) {
                let state = try await SkillsState.query(on: fluent.db())
                    .filter(\.$tenantID == tenantID)
                    .filter(\.$source == manifest.source.rawValue)
                    .filter(\.$name == manifest.name).first()
                if state?.workflowID != nil {
                    continue
                }
                guard let cron = state?.scheduleOverride ?? manifest.schedule,
                      (try? CronExpression(cron)) != nil
                else { continue }
                if let existing = try await Workflow.query(on: fluent.db(), tenantID: tenantID)
                    .filter(\.$legacySkillName == manifest.name).first()
                {
                    try await link(state: state, tenantID: tenantID, manifest: manifest, workflowID: existing.requireID())
                    continue
                }
                let trigger = WorkflowNodeDTO(kind: .trigger, name: "Schedule", x: 0, y: 120)
                let skill = WorkflowNodeDTO(kind: .skill, name: manifest.name, x: 260, y: 120, configuration: ["skillName": manifest.name])
                let output = WorkflowNodeDTO(kind: .output, name: "Output", x: 520, y: 120, configuration: ["value": "{{nodes.\(skill.id.uuidString).text}}"])
                let definition = WorkflowDefinitionDTO(
                    trigger: .schedule,
                    triggerConfiguration: ["cron": cron, "timezone": user.timezone],
                    nodes: [trigger, skill, output],
                    edges: [
                        .init(sourceNodeID: trigger.id, targetNodeID: skill.id),
                        .init(sourceNodeID: skill.id, targetNodeID: output.id),
                    ]
                )
                let workflow = Workflow(tenantID: tenantID, name: "Job · \(manifest.name)", descriptionText: manifest.description, definition: definition, isLegacyJob: true, legacySkillName: manifest.name)
                try await workflow.create(on: fluent.db())
                let version = WorkflowVersion(); version.id = UUID(); version.tenantID = tenantID
                version.workflowID = try workflow.requireID(); version.version = 1; version.definition = definition
                try await version.create(on: fluent.db())
                workflow.publishedVersionID = try version.requireID(); try await workflow.save(on: fluent.db())
                try await link(state: state, tenantID: tenantID, manifest: manifest, workflowID: workflow.requireID())
                count += 1
            }
        }
        return count
    }

    private func link(state: SkillsState?, tenantID: UUID, manifest: SkillManifest, workflowID: UUID) async throws {
        let row = state ?? SkillsState(tenantID: tenantID, source: manifest.source.rawValue, name: manifest.name)
        row.workflowID = workflowID
        try await row.save(on: fluent.db())
    }
}
