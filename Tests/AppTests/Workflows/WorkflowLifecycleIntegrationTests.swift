@testable import App
import Foundation
import LuminaVaultShared
import Testing

@Suite("Workflow lifecycle integration", .enabled(if: IntegrationTestEnv.runIntegrationOnly))
struct WorkflowLifecycleIntegrationTests {
    @Test func createsPublishesDeduplicatesAndCancelsRun() async throws {
        try await withTestFluent(label: "lv.test.workflow.lifecycle") { fluent in
            // Integration bases are primed through the legacy schema. Keep
            // this suite focused on the workflow migrations so unrelated
            // historical migrations cannot mask workflow regressions.
            await fluent.migrations.add(M92_CreateWorkflows())
            await fluent.migrations.add(M93_HardenWorkflowAutomation())
            await fluent.migrations.add(M100_CreateWorkflowWebhooks())
            try await fluent.migrate()
            let suffix = UUID().uuidString.lowercased()
            let user = User(email: "workflow-\(suffix)@example.test", username: "wf_\(suffix.prefix(12))", passwordHash: "test")
            try await user.create(on: fluent.db())
            let tenantID = try user.requireID()

            let trigger = WorkflowNodeDTO(kind: .trigger, name: "Webhook", x: 0, y: 0)
            let output = WorkflowNodeDTO(kind: .output, name: "Output", x: 200, y: 0, configuration: ["value": "{{event}}"])
            let definition = WorkflowDefinitionDTO(
                trigger: .webhook,
                nodes: [trigger, output],
                edges: [.init(sourceNodeID: trigger.id, targetNodeID: output.id)]
            )
            let service = WorkflowService(fluent: fluent)
            let created = try await service.create(tenantID: tenantID, request: .init(name: "Webhook \(suffix)", definition: definition))
            _ = try await service.publish(tenantID: tenantID, id: created.workflow.id)
            let first = try await service.enqueue(
                tenantID: tenantID, workflowID: created.workflow.id, trigger: .webhook,
                request: .init(input: ["event": "created"]), dedupeKey: "webhook:event-1"
            )
            let duplicate = try await service.enqueue(
                tenantID: tenantID, workflowID: created.workflow.id, trigger: .webhook,
                request: .init(input: ["event": "created"]), dedupeKey: "webhook:event-1"
            )
            #expect(first.id == duplicate.id)
            try await service.cancel(tenantID: tenantID, runID: first.id)
            let runs = try await service.runs(tenantID: tenantID, workflowID: created.workflow.id)
            #expect(runs.runs.first?.status == .cancelled)
        }
    }
}
