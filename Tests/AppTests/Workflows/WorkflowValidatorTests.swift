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
}
