import Foundation
import LuminaVaultShared

enum WorkflowValidationError: Error, Equatable {
    case missingTrigger
    case duplicateNodeID
    case unknownEdgeNode
    case cycle
    case unreachableNode
    case invalidIterationBound
    case parallelGroupTooLarge
    case expandedExecutionTooLarge
    case invalidParallelConfiguration
}

enum WorkflowValidator {
    static func validate(_ definition: WorkflowDefinitionDTO) throws {
        let ids = Set(definition.nodes.map(\.id))
        guard ids.count == definition.nodes.count else { throw WorkflowValidationError.duplicateNodeID }
        guard definition.nodes.count(where: { $0.kind == .trigger }) == 1 else { throw WorkflowValidationError.missingTrigger }
        guard definition.edges.allSatisfy({ ids.contains($0.sourceNodeID) && ids.contains($0.targetNodeID) }) else {
            throw WorkflowValidationError.unknownEdgeNode
        }
        let iterations = definition.nodes.map { Int($0.configuration["maxIterations"] ?? "1") ?? 0 }
        guard iterations.allSatisfy({ 1 ... 20 ~= $0 }) else { throw WorkflowValidationError.invalidIterationBound }
        guard zip(definition.nodes, iterations).reduce(0, { $0 + ($1.0.kind == .trigger ? 1 : $1.1) }) <= 100 else {
            throw WorkflowValidationError.expandedExecutionTooLarge
        }
        let parallelGroups = Dictionary(grouping: definition.nodes.compactMap { node in
            node.configuration["parallelGroup"].map { ($0, node.id) }
        }, by: \.0)
        guard parallelGroups.values.allSatisfy({ $0.count <= 8 }) else { throw WorkflowValidationError.parallelGroupTooLarge }
        let trigger = definition.nodes.first { $0.kind == .trigger }!.id
        var reachable: Set<UUID> = [trigger]
        var frontier = [trigger]
        while let next = frontier.popLast() {
            for id in definition.edges.lazy.filter({ $0.sourceNodeID == next }).map(\.targetNodeID) where reachable.insert(id).inserted {
                frontier.append(id)
            }
        }
        guard reachable.count == definition.nodes.count else { throw WorkflowValidationError.unreachableNode }

        var indegree = Dictionary(uniqueKeysWithValues: definition.nodes.map { ($0.id, 0) })
        for edge in definition.edges {
            indegree[edge.targetNodeID, default: 0] += 1
        }
        var queue = indegree.filter { $0.value == 0 }.map(\.key)
        var visited = 0
        while let id = queue.popLast() {
            visited += 1
            for target in definition.edges.lazy.filter({ $0.sourceNodeID == id }).map(\.targetNodeID) {
                indegree[target, default: 0] -= 1
                if indegree[target] == 0 {
                    queue.append(target)
                }
            }
        }
        guard visited == definition.nodes.count else { throw WorkflowValidationError.cycle }
        for node in definition.nodes where node.kind == .parallel {
            guard definition.edges.count(where: { $0.sourceNodeID == node.id }) >= 2 else {
                throw WorkflowValidationError.invalidParallelConfiguration
            }
        }
    }
}
