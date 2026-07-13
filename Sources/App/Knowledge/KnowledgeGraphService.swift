import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared
import SQLKit

struct KnowledgeGraphFilter {
    var kinds: Set<KnowledgeNodeKindDTO> = []
    var predicates: Set<KnowledgeEdgePredicateDTO> = []
    var states: Set<KnowledgeEdgeStateDTO> = [.asserted, .suggested, .confirmed]
    var minimumConfidence: Double = 0
}

struct KnowledgeGraphService {
    let fluent: Fluent

    static let defaultLimit = 800
    static let maxLimit = 2000
    static let maxDepth = 4

    func graph(tenantID: UUID, limit: Int, filter: KnowledgeGraphFilter) async throws -> KnowledgeGraphResponse {
        let sql = try requireSQL()
        let nodeRows = try await sql.raw("""
        SELECT id, kind, label, summary, occurred_at, confidence
        FROM knowledge_nodes
        WHERE tenant_id = \(bind: tenantID)
        ORDER BY updated_at DESC, id ASC
        LIMIT \(bind: min(max(1, limit), Self.maxLimit))
        """).all(decoding: NodeRow.self)
        let filteredNodes = nodeRows.filter {
            (filter.kinds.isEmpty || filter.kinds.contains($0.nodeKind))
                && $0.confidence >= filter.minimumConfidence
        }
        let nodeIDs = Set(filteredNodes.map(\.id))
        guard !nodeIDs.isEmpty else {
            return KnowledgeGraphResponse(nodes: [], edges: [], generatedAt: Date())
        }
        let edgeRows = try await sql.raw("""
        SELECT id, from_node_id, to_node_id, predicate, state, confidence,
               rationale, counter_evidence
        FROM knowledge_edges
        WHERE tenant_id = \(bind: tenantID)
          AND from_node_id = ANY(\(unsafeRaw: Self.uuidArray(nodeIDs)))
          AND to_node_id = ANY(\(unsafeRaw: Self.uuidArray(nodeIDs)))
        ORDER BY confidence DESC, id ASC
        LIMIT \(bind: Self.maxLimit * 8)
        """).all(decoding: EdgeRow.self)
        let filteredEdges = edgeRows.filter {
            filter.states.contains($0.edgeState)
                && (filter.predicates.isEmpty || filter.predicates.contains($0.edgePredicate))
                && $0.confidence >= filter.minimumConfidence
        }
        let evidence = try await loadEvidence(
            sql: sql,
            tenantID: tenantID,
            nodeIDs: nodeIDs,
            edgeIDs: Set(filteredEdges.map(\.id))
        )
        return KnowledgeGraphResponse(
            nodes: filteredNodes.map { $0.dto(evidence: evidence.nodes[$0.id] ?? []) },
            edges: filteredEdges.map { $0.dto(evidence: evidence.edges[$0.id] ?? []) },
            generatedAt: Date()
        )
    }

    func explain(
        tenantID: UUID,
        from: UUID,
        to: UUID,
        maxDepth: Int
    ) async throws -> ConnectionExplanationResponse {
        guard from != to else { throw HTTPError(.badRequest, message: "choose two different nodes") }
        let sql = try requireSQL()
        let depth = min(max(1, maxDepth), Self.maxDepth)
        let rows = try await sql.raw("""
        WITH RECURSIVE paths(current_id, node_ids, edge_ids, path_confidence, depth) AS (
            SELECT \(bind: from)::uuid, ARRAY[\(bind: from)::uuid], ARRAY[]::uuid[], 1.0::double precision, 0
            UNION ALL
            SELECT
                CASE WHEN e.from_node_id = p.current_id THEN e.to_node_id ELSE e.from_node_id END,
                p.node_ids || CASE WHEN e.from_node_id = p.current_id THEN e.to_node_id ELSE e.from_node_id END,
                p.edge_ids || e.id,
                p.path_confidence * e.confidence,
                p.depth + 1
            FROM paths p
            JOIN knowledge_edges e
              ON e.tenant_id = \(bind: tenantID)
             AND (e.from_node_id = p.current_id OR e.to_node_id = p.current_id)
             AND e.state IN ('asserted', 'suggested', 'confirmed')
            WHERE p.depth < \(bind: depth)
              AND NOT (CASE WHEN e.from_node_id = p.current_id THEN e.to_node_id ELSE e.from_node_id END = ANY(p.node_ids))
        )
        SELECT node_ids, edge_ids, path_confidence
        FROM paths
        WHERE current_id = \(bind: to)
        ORDER BY path_confidence DESC, array_length(edge_ids, 1) ASC
        LIMIT 5
        """).all(decoding: PathRow.self)
        guard !rows.isEmpty else {
            return ConnectionExplanationResponse(
                explanation: "No evidence-backed connection was found within \(depth) steps.",
                paths: [],
                confidence: 0,
                caveats: ["The graph may still be processing recent memories."]
            )
        }
        let graph = try await graph(tenantID: tenantID, limit: Self.maxLimit, filter: .init())
        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let edges = Dictionary(uniqueKeysWithValues: graph.edges.map { ($0.id, $0) })
        let paths = rows.compactMap { row -> KnowledgePathDTO? in
            let pathNodes = row.node_ids.compactMap { nodes[$0] }
            let pathEdges = row.edge_ids.compactMap { edges[$0] }
            guard pathNodes.count == row.node_ids.count, pathEdges.count == row.edge_ids.count else { return nil }
            return KnowledgePathDTO(nodes: pathNodes, edges: pathEdges, confidence: row.path_confidence)
        }
        guard let best = paths.first else {
            throw HTTPError(.internalServerError, message: "connection path could not be hydrated")
        }
        let steps: String = best.edges.enumerated().map { index, edge -> String in
            let destination = best.nodes[index + 1].label
            return "\(edge.predicate.displayName) \(destination)"
        }.joined(separator: ", then ")
        let inferred = best.edges.contains { $0.state == .suggested }
        return ConnectionExplanationResponse(
            explanation: "\(best.nodes[0].label) connects to \(best.nodes.last?.label ?? "the selected node") because it \(steps).",
            paths: paths,
            confidence: best.confidence,
            caveats: inferred ? ["This path includes a machine-inferred connection that has not been confirmed."] : []
        )
    }

    func reason(tenantID: UUID, request: ReasoningQueryRequest) async throws -> ReasoningQueryResponse {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw HTTPError(.badRequest, message: "query required") }
        let graph = try await graph(
            tenantID: tenantID,
            limit: min(max(1, request.limit ?? 200), Self.maxLimit),
            filter: .init()
        )
        let words = query.lowercased().split { character in
            character.isLetter == false && character.isNumber == false
        }
        let terms = Set(words.map { String($0) }.filter { $0.count > 2 })
        var ranked: [(node: KnowledgeNodeDTO, score: Int)] = []
        ranked.reserveCapacity(graph.nodes.count)
        for node in graph.nodes {
            let haystack = "\(node.label) \(node.summary ?? "")".lowercased()
            let score = terms.reduce(into: 0) { total, term in
                if haystack.contains(term) {
                    total += 1
                }
            }
            if score > 0 {
                ranked.append((node: node, score: score))
            }
        }
        ranked.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.node.confidence > rhs.node.confidence : lhs.score > rhs.score
        }
        let selected: [KnowledgeNodeDTO] = ranked.prefix(6).map(\.node)
        let selectedIDs = Set(selected.map(\.id))
        let edges: [KnowledgeEdgeDTO] = graph.edges.filter { edge in
            selectedIDs.contains(edge.from) || selectedIDs.contains(edge.to)
        }
        let nodeEvidence = selected.flatMap(\.evidence)
        let edgeEvidence = edges.flatMap(\.evidence)
        let evidence = Self.uniqueEvidence(nodeEvidence + edgeEvidence)
        let suggestions = edges.filter { $0.state == KnowledgeEdgeStateDTO.suggested }
        guard !selected.isEmpty else {
            return ReasoningQueryResponse(
                answer: "I could not find an evidence-backed graph match for that question.",
                paths: [], evidence: [], confidence: 0,
                caveats: ["Try naming a person, concept, event, or claim found in your memories."]
            )
        }
        let summary = selected.map(\.label).joined(separator: "; ")
        let paths = Self.reasoningPaths(
            graph: graph,
            seedIDs: selectedIDs,
            maxDepth: min(max(1, request.maxDepth ?? Self.maxDepth), Self.maxDepth),
            limit: 5
        )
        let pathEvidence = paths.flatMap { path in
            path.nodes.flatMap(\.evidence) + path.edges.flatMap(\.evidence)
        }
        let groundedEvidence = Self.uniqueEvidence(evidence + pathEvidence)
        let totalConfidence = selected.reduce(into: 0.0) { total, node in
            total += node.confidence
        }
        let pathConfidence = paths.first?.confidence ?? totalConfidence / Double(selected.count)
        return ReasoningQueryResponse(
            answer: "The strongest graph evidence points to: \(summary).",
            paths: paths, evidence: groundedEvidence,
            confidence: pathConfidence,
            caveats: suggestions.isEmpty ? [] : ["Some matching connections are inferred and await review."],
            suggestions: suggestions
        )
    }

    func review(tenantID: UUID, edgeID: UUID, state: KnowledgeEdgeStateDTO, note: String?) async throws -> KnowledgeEdgeDTO {
        guard state == .confirmed || state == .dismissed else {
            throw HTTPError(.badRequest, message: "invalid review state")
        }
        let sql = try requireSQL()
        guard let row = try await sql.raw("""
        UPDATE knowledge_edges
        SET state = \(bind: state.rawValue), review_note = \(bind: note), reviewed_at = NOW(), updated_at = NOW()
        WHERE tenant_id = \(bind: tenantID) AND id = \(bind: edgeID) AND state = 'suggested'
        RETURNING id, from_node_id, to_node_id, predicate, state, confidence, rationale, counter_evidence
        """).first(decoding: EdgeRow.self) else {
            throw HTTPError(.notFound, message: "reviewable inference not found")
        }
        let evidence = try await loadEvidence(sql: sql, tenantID: tenantID, nodeIDs: [], edgeIDs: [edgeID])
        return row.dto(evidence: evidence.edges[edgeID] ?? [])
    }

    private func requireSQL() throws -> any SQLDatabase {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for knowledge graph")
        }
        return sql
    }

    private func loadEvidence(
        sql: any SQLDatabase,
        tenantID: UUID,
        nodeIDs: Set<UUID>,
        edgeIDs: Set<UUID>
    ) async throws -> (nodes: [UUID: [KnowledgeEvidenceDTO]], edges: [UUID: [KnowledgeEvidenceDTO]]) {
        guard !nodeIDs.isEmpty || !edgeIDs.isEmpty else { return ([:], [:]) }
        let rows = try await sql.raw("""
        SELECT id, node_id, edge_id, memory_id, source_vault_file_id, quote, start_offset, end_offset
        FROM knowledge_evidence
        WHERE tenant_id = \(bind: tenantID)
          AND (node_id = ANY(\(unsafeRaw: Self.uuidArray(nodeIDs))) OR edge_id = ANY(\(unsafeRaw: Self.uuidArray(edgeIDs))))
        ORDER BY created_at ASC, id ASC
        """).all(decoding: EvidenceRow.self)
        var nodes: [UUID: [KnowledgeEvidenceDTO]] = [:]
        var edges: [UUID: [KnowledgeEvidenceDTO]] = [:]
        for row in rows {
            if let id = row.node_id {
                nodes[id, default: []].append(row.dto)
            }
            if let id = row.edge_id {
                edges[id, default: []].append(row.dto)
            }
        }
        return (nodes, edges)
    }

    private static func uuidArray(_ ids: some Collection<UUID>) -> String {
        guard !ids.isEmpty else { return "ARRAY[]::uuid[]" }
        return "ARRAY[" + ids.map { "'\($0.uuidString)'::uuid" }.joined(separator: ",") + "]"
    }

    private static func uniqueEvidence(_ values: [KnowledgeEvidenceDTO]) -> [KnowledgeEvidenceDTO] {
        var seen: Set<UUID> = []
        return values.filter { seen.insert($0.id).inserted }
    }

    static func reasoningPaths(
        graph: KnowledgeGraphResponse,
        seedIDs: Set<UUID>,
        maxDepth: Int,
        limit: Int
    ) -> [KnowledgePathDTO] {
        guard seedIDs.count > 1, maxDepth > 0, limit > 0 else { return [] }
        let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        var adjacency: [UUID: [(next: UUID, edge: KnowledgeEdgeDTO)]] = [:]
        for edge in graph.edges where edge.state != .dismissed && edge.state != .stale {
            adjacency[edge.from, default: []].append((edge.to, edge))
            adjacency[edge.to, default: []].append((edge.from, edge))
        }
        struct Candidate {
            let nodeIDs: [UUID]
            let edges: [KnowledgeEdgeDTO]
            let confidence: Double
        }
        var results: [Candidate] = []
        for start in seedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            var queue = [Candidate(nodeIDs: [start], edges: [], confidence: 1)]
            var cursor = 0
            while cursor < queue.count, results.count < limit * 4 {
                let candidate = queue[cursor]
                cursor += 1
                guard candidate.edges.count < maxDepth, let current = candidate.nodeIDs.last else { continue }
                for next in adjacency[current, default: []] {
                    guard candidate.nodeIDs.contains(next.next) == false else { continue }
                    let expanded = Candidate(
                        nodeIDs: candidate.nodeIDs + [next.next],
                        edges: candidate.edges + [next.edge],
                        confidence: candidate.confidence * next.edge.confidence
                    )
                    if seedIDs.contains(next.next), next.next != start {
                        results.append(expanded)
                    } else {
                        queue.append(expanded)
                    }
                }
            }
        }
        var fingerprints: Set<String> = []
        return results
            .sorted {
                $0.confidence == $1.confidence
                    ? $0.edges.count < $1.edges.count
                    : $0.confidence > $1.confidence
            }
            .filter { candidate in
                let forward = candidate.nodeIDs.map(\.uuidString).joined(separator: ":")
                let reverse = candidate.nodeIDs.reversed().map(\.uuidString).joined(separator: ":")
                return fingerprints.insert(min(forward, reverse)).inserted
            }
            .prefix(limit)
            .compactMap { candidate in
                let nodes = candidate.nodeIDs.compactMap { nodesByID[$0] }
                guard nodes.count == candidate.nodeIDs.count else { return nil }
                return KnowledgePathDTO(nodes: nodes, edges: candidate.edges, confidence: candidate.confidence)
            }
    }
}

private struct NodeRow: Decodable {
    let id: UUID
    let kind: String
    let label: String
    let summary: String?
    let occurred_at: Date?
    let confidence: Double
    var nodeKind: KnowledgeNodeKindDTO {
        KnowledgeNodeKindDTO(rawValue: kind) ?? .claim
    }

    func dto(evidence: [KnowledgeEvidenceDTO]) -> KnowledgeNodeDTO {
        KnowledgeNodeDTO(id: id, kind: nodeKind, label: label, summary: summary, occurredAt: occurred_at, confidence: confidence, evidence: evidence)
    }
}

private struct EdgeRow: Decodable {
    let id: UUID
    let from_node_id: UUID
    let to_node_id: UUID
    let predicate: String
    let state: String
    let confidence: Double
    let rationale: String?
    let counter_evidence: String?
    var edgePredicate: KnowledgeEdgePredicateDTO {
        KnowledgeEdgePredicateDTO(rawValue: predicate) ?? .relatedTo
    }

    var edgeState: KnowledgeEdgeStateDTO {
        KnowledgeEdgeStateDTO(rawValue: state) ?? .suggested
    }

    func dto(evidence: [KnowledgeEvidenceDTO]) -> KnowledgeEdgeDTO {
        KnowledgeEdgeDTO(id: id, from: from_node_id, to: to_node_id, predicate: edgePredicate, state: edgeState, confidence: confidence, rationale: rationale, counterEvidence: counter_evidence, evidence: evidence)
    }
}

private struct EvidenceRow: Decodable {
    let id: UUID
    let node_id: UUID?
    let edge_id: UUID?
    let memory_id: UUID
    let source_vault_file_id: UUID?
    let quote: String
    let start_offset: Int?
    let end_offset: Int?
    var dto: KnowledgeEvidenceDTO {
        KnowledgeEvidenceDTO(id: id, memoryID: memory_id, sourceVaultFileID: source_vault_file_id, quote: quote, startOffset: start_offset, endOffset: end_offset)
    }
}

private struct PathRow: Decodable {
    let node_ids: [UUID]
    let edge_ids: [UUID]
    let path_confidence: Double
}

private extension KnowledgeEdgePredicateDTO {
    var displayName: String {
        switch self {
        case .mentions: "mentions"
        case .about: "is about"
        case .supports: "supports"
        case .contradicts: "contradicts"
        case .causes: "causes"
        case .precedes: "precedes"
        case .relatedTo: "relates to"
        case .derivedFrom: "is derived from"
        }
    }
}
