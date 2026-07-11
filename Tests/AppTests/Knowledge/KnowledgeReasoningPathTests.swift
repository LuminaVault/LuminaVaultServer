@testable import App
import Foundation
import LuminaVaultShared
import Testing

struct KnowledgeReasoningPathTests {
    @Test("Reasoning paths are cycle-safe, confidence-ranked, and depth bounded")
    func rankedPaths() throws {
        let a = node("A"), b = node("B"), c = node("C"), d = node("D")
        let graph = KnowledgeGraphResponse(
            nodes: [a, b, c, d],
            edges: [
                edge(a, b, confidence: 0.9),
                edge(b, c, confidence: 0.8),
                edge(c, a, confidence: 0.2),
                edge(c, d, confidence: 0.95),
            ],
            generatedAt: Date()
        )

        let paths = KnowledgeGraphService.reasoningPaths(
            graph: graph,
            seedIDs: [a.id, c.id, d.id],
            maxDepth: 3,
            limit: 5
        )

        let first = try #require(paths.first)
        #expect(first.nodes.first?.id == c.id || first.nodes.first?.id == d.id)
        #expect(first.nodes.last?.id == d.id || first.nodes.last?.id == c.id)
        #expect(first.edges.count == 1)
        #expect(paths.allSatisfy { $0.edges.count <= 3 })
        #expect(paths.allSatisfy { Set($0.nodes.map(\.id)).count == $0.nodes.count })
    }

    @Test("Dismissed and stale edges never ground reasoning")
    func excludesInactiveEdges() {
        let a = node("A"), b = node("B")
        let graph = KnowledgeGraphResponse(
            nodes: [a, b],
            edges: [edge(a, b, state: .dismissed, confidence: 1)],
            generatedAt: Date()
        )

        let paths = KnowledgeGraphService.reasoningPaths(
            graph: graph,
            seedIDs: [a.id, b.id],
            maxDepth: 4,
            limit: 5
        )

        #expect(paths.isEmpty)
    }

    private func node(_ label: String) -> KnowledgeNodeDTO {
        KnowledgeNodeDTO(id: UUID(), kind: .claim, label: label, confidence: 1)
    }

    private func edge(
        _ from: KnowledgeNodeDTO,
        _ to: KnowledgeNodeDTO,
        state: KnowledgeEdgeStateDTO = .asserted,
        confidence: Double
    ) -> KnowledgeEdgeDTO {
        KnowledgeEdgeDTO(
            id: UUID(), from: from.id, to: to.id, predicate: .relatedTo,
            state: state, confidence: confidence
        )
    }
}
