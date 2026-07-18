@testable import App
import Foundation
import LuminaVaultShared
import Testing

@Suite("Workflow graph validation")
struct WorkflowValidatorTests {
    @Test func acceptsReachableDAG() throws {
        let trigger = WorkflowNodeDTO(kind: .trigger, name: "Manual", x: 0, y: 0)
        let output = WorkflowNodeDTO(kind: .output, name: "Output", x: 200, y: 0)
        let definition = WorkflowDefinitionDTO(trigger: .manual, nodes: [trigger, output], edges: [WorkflowEdgeDTO(sourceNodeID: trigger.id, targetNodeID: output.id)])
        try WorkflowValidator.validate(definition)
    }

    @Test func rejectsCycles() {
        let trigger = WorkflowNodeDTO(kind: .trigger, name: "Manual", x: 0, y: 0)
        let first = WorkflowNodeDTO(kind: .template, name: "First", x: 200, y: 0)
        let second = WorkflowNodeDTO(kind: .output, name: "Second", x: 400, y: 0)
        let definition = WorkflowDefinitionDTO(trigger: .manual, nodes: [trigger, first, second], edges: [
            WorkflowEdgeDTO(sourceNodeID: trigger.id, targetNodeID: first.id),
            WorkflowEdgeDTO(sourceNodeID: first.id, targetNodeID: second.id),
            WorkflowEdgeDTO(sourceNodeID: second.id, targetNodeID: first.id),
        ])
        #expect(throws: WorkflowValidationError.cycle) { try WorkflowValidator.validate(definition) }
    }

    @Test func rejectsUnreachableNodes() {
        let trigger = WorkflowNodeDTO(kind: .trigger, name: "Manual", x: 0, y: 0)
        let orphan = WorkflowNodeDTO(kind: .output, name: "Orphan", x: 200, y: 0)
        let definition = WorkflowDefinitionDTO(trigger: .manual, nodes: [trigger, orphan], edges: [])
        #expect(throws: WorkflowValidationError.unreachableNode) { try WorkflowValidator.validate(definition) }
    }

    @Test func rejectsLoopNodesInReliableCore() {
        let trigger = WorkflowNodeDTO(kind: .trigger, name: "Manual", x: 0, y: 0)
        let loop = WorkflowNodeDTO(kind: .whileLoop, name: "Loop", x: 200, y: 0, configuration: ["maxIterations": "21"])
        let definition = WorkflowDefinitionDTO(trigger: .manual, nodes: [trigger, loop], edges: [WorkflowEdgeDTO(sourceNodeID: trigger.id, targetNodeID: loop.id)])
        #expect(throws: WorkflowValidationError.unsupportedNodeKind(.whileLoop)) {
            try WorkflowValidator.validate(definition)
        }
    }

    @Test(
        "Reliable core rejects deferred execution shapes",
        arguments: [WorkflowNodeKind.parallel, .forEach]
    )
    func rejectsDeferredExecutionShapes(kind: WorkflowNodeKind) {
        let trigger = WorkflowNodeDTO(kind: .trigger, name: "Manual", x: 0, y: 0)
        let deferred = WorkflowNodeDTO(kind: kind, name: "Deferred", x: 200, y: 0)
        let definition = WorkflowDefinitionDTO(
            trigger: .manual,
            nodes: [trigger, deferred],
            edges: [WorkflowEdgeDTO(sourceNodeID: trigger.id, targetNodeID: deferred.id)]
        )

        #expect(throws: WorkflowValidationError.unsupportedNodeKind(kind)) {
            try WorkflowValidator.validate(definition)
        }
    }

    @Test func rejectsUnknownSchemaVersions() {
        let trigger = WorkflowNodeDTO(kind: .trigger, name: "Manual", x: 0, y: 0)
        let definition = WorkflowDefinitionDTO(schemaVersion: 2, trigger: .manual, nodes: [trigger], edges: [])

        #expect(throws: WorkflowValidationError.unsupportedSchemaVersion(2)) {
            try WorkflowValidator.validate(definition)
        }
    }

    @Test func rejectsOversizedParallelGroups() {
        let trigger = WorkflowNodeDTO(kind: .trigger, name: "Manual", x: 0, y: 0)
        let nodes = (0 ... WorkflowExecutionBounds.maxParallelNodes).map {
            WorkflowNodeDTO(kind: .template, name: "Branch \($0)", x: Double($0), y: 0, configuration: ["parallelGroup": "fanout"])
        }
        let definition = WorkflowDefinitionDTO(trigger: .manual, nodes: [trigger] + nodes, edges: nodes.map { WorkflowEdgeDTO(sourceNodeID: trigger.id, targetNodeID: $0.id) })
        #expect(throws: WorkflowValidationError.parallelGroupTooLarge) { try WorkflowValidator.validate(definition) }
    }
}

@Suite("Workflow tier policies")
struct WorkflowTierPolicyTests {
    struct Expectation: Sendable {
        let tier: UserTier
        let activeRuns: Int
        let scheduleMinutes: Int
        let runMicros: Int64
        let dayMicros: Int64
        let monthMicros: Int64
    }

    @Test(
        "Paid tiers keep their managed inference and concurrency caps",
        arguments: [
            Expectation(tier: .pro, activeRuns: 1, scheduleMinutes: 60, runMicros: 200_000, dayMicros: 500_000, monthMicros: 2_000_000),
            Expectation(tier: .ultimate, activeRuns: 3, scheduleMinutes: 5, runMicros: 1_000_000, dayMicros: 2_000_000, monthMicros: 8_000_000),
        ]
    )
    func paidTierCaps(expectation: Expectation) {
        let policy = WorkflowTierPolicy.policy(for: expectation.tier)

        #expect(policy.activeRunLimit == expectation.activeRuns)
        #expect(policy.minimumScheduleMinutes == expectation.scheduleMinutes)
        #expect(policy.perRunUsdMicros == expectation.runMicros)
        #expect(policy.dailyUsdMicros == expectation.dayMicros)
        #expect(policy.monthlyUsdMicros == expectation.monthMicros)
    }

    @Test("Non-authoring tiers have no execution allowance", arguments: [UserTier.trial, .lapsed, .archived])
    func nonAuthoringTiers(tier: UserTier) {
        let policy = WorkflowTierPolicy.policy(for: tier)

        #expect(policy.activeRunLimit == 0)
        #expect(policy.perRunUsdMicros == 0)
    }
}

@Suite("Workflow scheduling policies")
struct WorkflowSchedulePolicyTests {
    @Test func proRejectsSubHourlySchedule() {
        let definition = scheduledDefinition(cron: "*/30 * * * *")

        #expect(throws: WorkflowSchedulePolicyError.scheduleTooFrequent(minimumMinutes: 60)) {
            try WorkflowSchedulePolicy.validate(definition: definition, minimumMinutes: 60)
        }
    }

    @Test func ultimateAcceptsFiveMinuteSchedule() {
        let definition = scheduledDefinition(cron: "*/5 * * * *")

        #expect(throws: Never.self) {
            try WorkflowSchedulePolicy.validate(definition: definition, minimumMinutes: 5)
        }
    }

    @Test func rejectsInvalidCron() {
        let definition = scheduledDefinition(cron: "not-a-cron")

        #expect(throws: WorkflowSchedulePolicyError.invalidCron) {
            try WorkflowSchedulePolicy.validate(definition: definition, minimumMinutes: 5)
        }
    }

    private func scheduledDefinition(cron: String) -> WorkflowDefinitionDTO {
        let trigger = WorkflowNodeDTO(kind: .trigger, name: "Schedule", x: 0, y: 0)
        return WorkflowDefinitionDTO(
            trigger: .schedule,
            triggerConfiguration: ["cron": cron, "timezone": "UTC"],
            nodes: [trigger],
            edges: []
        )
    }
}
