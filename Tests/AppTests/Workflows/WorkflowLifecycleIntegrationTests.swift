@testable import App
import Foundation
import Logging
import LuminaVaultShared
import Testing

@Suite("Workflow lifecycle integration", .enabled(if: IntegrationTestEnv.runIntegrationOnly))
struct WorkflowLifecycleIntegrationTests {
    @Test func `creates publishes deduplicates and cancels run`() async throws {
        try await withTestFluent(label: "lv.test.workflow.lifecycle") { fluent in
            // Integration bases are primed through the legacy schema. Keep
            // this suite focused on the workflow migrations so unrelated
            // historical migrations cannot mask workflow regressions.
            await fluent.migrations.add(M92_CreateWorkflows())
            await fluent.migrations.add(M93_HardenWorkflowAutomation())
            await fluent.migrations.add(M100_CreateWorkflowWebhooks())
            await fluent.migrations.add(M109_CerberusStudio())
            try await fluent.migrate()
            let suffix = UUID().uuidString.lowercased()
            let user = User(
                email: "workflow-\(suffix)@example.test",
                username: "wf_\(suffix.prefix(12))",
                passwordHash: "test",
                tier: UserTier.pro.rawValue
            )
            try await user.create(on: fluent.db())
            let tenantID = try user.requireID()

            let trigger = WorkflowNodeDTO(kind: .trigger, name: "Webhook", x: 0, y: 0)
            let output = WorkflowNodeDTO(kind: .output, name: "Output", x: 200, y: 0, configuration: ["value": "{{event}}"])
            let definition = WorkflowDefinitionDTO(
                trigger: .webhook,
                nodes: [trigger, output],
                edges: [.init(sourceNodeID: trigger.id, targetNodeID: output.id)]
            )
            let spend = WorkflowSpendService(
                fluent: fluent,
                logger: Logger(label: "lv.test.workflow.spend"),
                managedInferenceAvailable: true
            )
            let service = WorkflowService(fluent: fluent, spend: spend)
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

            let reservation = try await spend.reserveManagedCall(
                tenantID: tenantID,
                runID: first.id,
                tier: .pro
            )
            await spend.reconcile(reservation, actualUsdMicros: 12345)
            let limits = await spend.limits(tenantID: tenantID, tier: .pro)
            #expect(limits.activeRuns == 1)
            #expect(limits.dailySpentUsdMicros == 12345)
            #expect(limits.monthlySpentUsdMicros == 12345)

            let detail = try await service.run(tenantID: tenantID, runID: first.id)
            #expect(detail.managedSpendUsdMicros == 12345)
            #expect(detail.managedSpendLimitUsdMicros == 200_000)

            try await service.cancel(tenantID: tenantID, runID: first.id)

            // Separate service actors model two API replicas racing on the
            // same webhook delivery. The unique index remains the final guard.
            let replica = WorkflowService(fluent: fluent, spend: spend)
            async let replicaOne = service.enqueue(
                tenantID: tenantID, workflowID: created.workflow.id, trigger: .webhook,
                request: .init(input: ["event": "raced"]), dedupeKey: "webhook:event-2"
            )
            async let replicaTwo = replica.enqueue(
                tenantID: tenantID, workflowID: created.workflow.id, trigger: .webhook,
                request: .init(input: ["event": "raced"]), dedupeKey: "webhook:event-2"
            )
            let raced = try await (replicaOne, replicaTwo)
            #expect(raced.0.id == raced.1.id)
            try await service.cancel(tenantID: tenantID, runID: raced.0.id)

            let runs = try await service.runs(tenantID: tenantID, workflowID: created.workflow.id)
            #expect(runs.runs.first?.status == .cancelled)
        }
    }
}
