import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared
import SQLKit

/// HER-235 — derives a tenant-scoped graph view of memories on read.
///
/// v1 ships **no persistence**: edges are computed from data already on
/// `memories` (shared `tags` + pgvector `embedding`). A later iteration can
/// materialise a `memory_edges` table without changing this contract.
///
/// Concurrency: pure read service. `Fluent` is `Sendable` (wraps the
/// connection pool); the struct holds no mutable state so a value-type
/// implementation suffices — no `actor` needed.
struct MemoryGraphService {
    let fluent: Fluent

    // ── Public defaults (mirror openapi.yaml). Controller is responsible
    //    for clamping; these are the canonical fallback values when a query
    //    param is absent.
    static let defaultLimit = 500
    static let maxLimit = 2000
    static let defaultSimilarity = 0.78
    static let defaultMaxEdgesPerNode = 8
    static let maxMaxEdgesPerNode = 50

    /// Computes the derived graph for `tenantID`.
    ///
    /// - Parameters:
    ///   - limit: Max nodes returned (top-scored first).
    ///   - similarity: Floor for cosine similarity edges (1 − pgvector `<=>`).
    ///   - maxEdgesPerNode: Per-node cap after tag + semantic edges merge.
    func graph(
        tenantID: UUID,
        limit: Int,
        similarity: Double,
        maxEdgesPerNode: Int,
    ) async throws -> MemoryGraphResponse {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for graph query")
        }

        let nodeRows = try await fetchNodes(sql: sql, tenantID: tenantID, limit: limit)
        guard !nodeRows.isEmpty else {
            return MemoryGraphResponse(nodes: [], edges: [], generatedAt: Date())
        }
        let nodeIDs = nodeRows.map(\.id)

        async let tagEdgesTask = computeTagEdges(sql: sql, tenantID: tenantID, ids: nodeIDs)
        async let semanticEdgesTask = computeSemanticEdges(
            sql: sql,
            tenantID: tenantID,
            ids: nodeIDs,
            similarity: similarity,
            maxEdgesPerNode: maxEdgesPerNode,
        )
        let tagEdges = try await tagEdgesTask
        let semanticEdges = try await semanticEdgesTask

        let merged = Self.mergeAndCap(
            tagEdges: tagEdges,
            semanticEdges: semanticEdges,
            maxEdgesPerNode: maxEdgesPerNode,
        )

        let nodes = nodeRows.map { row -> MemoryGraphNodeDTO in
            MemoryGraphNodeDTO(
                id: row.id,
                title: Self.titleFromContent(row.content),
                tags: row.tags ?? [],
                createdAt: row.created_at ?? Date(timeIntervalSince1970: 0),
                score: row.score,
            )
        }
        return MemoryGraphResponse(nodes: nodes, edges: merged, generatedAt: Date())
    }

    // MARK: - Node selection

    private func fetchNodes(sql: any SQLDatabase, tenantID: UUID, limit: Int) async throws -> [NodeRow] {
        try await sql.raw("""
        SELECT id, content, tags, created_at, score
        FROM memories
        WHERE tenant_id = \(bind: tenantID)
        ORDER BY score DESC, last_accessed_at DESC NULLS LAST, id ASC
        LIMIT \(bind: limit)
        """).all(decoding: NodeRow.self)
    }

    // MARK: - Tag edges

    /// One edge per pair that shares ≥1 tag. The shared tag chosen is the
    /// lexicographically smallest (`min(tag)`) so the result is deterministic
    /// across runs. Weight is fixed at 1.0; tag overlap is a binary signal.
    private func computeTagEdges(
        sql: any SQLDatabase,
        tenantID: UUID,
        ids: [UUID],
    ) async throws -> [MemoryGraphEdgeDTO] {
        let idArray = Self.formatUUIDArray(ids)
        let rows = try await sql.raw("""
        WITH node_tags AS (
            SELECT id, unnest(tags) AS tag
            FROM memories
            WHERE tenant_id = \(bind: tenantID) AND id = ANY(\(unsafeRaw: idArray))
        )
        SELECT a.id AS from_id,
               b.id AS to_id,
               MIN(a.tag) AS tag
        FROM node_tags a
        JOIN node_tags b ON a.tag = b.tag AND a.id < b.id
        GROUP BY a.id, b.id
        """).all(decoding: TagEdgeRow.self)
        return rows.map {
            MemoryGraphEdgeDTO(
                from: $0.from_id,
                to: $0.to_id,
                kind: .tag,
                tag: $0.tag,
                similarity: nil,
                weight: 1.0,
            )
        }
    }

    // MARK: - Semantic edges

    /// Each node's top-K nearest neighbours (`<=>` is pgvector cosine
    /// distance; similarity = 1 - distance). Bi-directional candidates are
    /// collapsed to undirected edges via `LEAST`/`GREATEST` ordering, keeping
    /// the higher similarity when both endpoints chose each other.
    private func computeSemanticEdges(
        sql: any SQLDatabase,
        tenantID: UUID,
        ids: [UUID],
        similarity: Double,
        maxEdgesPerNode: Int,
    ) async throws -> [MemoryGraphEdgeDTO] {
        let idArray = Self.formatUUIDArray(ids)
        let rows = try await sql.raw("""
        WITH neighbors AS (
            SELECT a.id AS from_id,
                   b.id AS to_id,
                   1 - (a.embedding <=> b.embedding) AS similarity,
                   ROW_NUMBER() OVER (
                       PARTITION BY a.id
                       ORDER BY a.embedding <=> b.embedding
                   ) AS rn
            FROM memories a
            JOIN memories b
              ON a.tenant_id = b.tenant_id AND a.id <> b.id
            WHERE a.tenant_id = \(bind: tenantID)
              AND a.id = ANY(\(unsafeRaw: idArray))
              AND b.id = ANY(\(unsafeRaw: idArray))
              AND a.embedding IS NOT NULL
              AND b.embedding IS NOT NULL
        )
        SELECT LEAST(from_id, to_id) AS from_id,
               GREATEST(from_id, to_id) AS to_id,
               MAX(similarity) AS similarity
        FROM neighbors
        WHERE rn <= \(bind: maxEdgesPerNode)
          AND similarity >= \(bind: similarity)
        GROUP BY LEAST(from_id, to_id), GREATEST(from_id, to_id)
        """).all(decoding: SemanticEdgeRow.self)
        return rows.map {
            MemoryGraphEdgeDTO(
                from: $0.from_id,
                to: $0.to_id,
                kind: .semantic,
                tag: nil,
                similarity: $0.similarity,
                weight: $0.similarity,
            )
        }
    }

    // MARK: - Merge + cap

    /// Combines tag + semantic edges (tag wins on dedupe — explicit signal
    /// beats inferred similarity), then prunes greedily: walk edges by
    /// weight DESC and admit an edge only when **both** endpoints still have
    /// remaining capacity. This is the only policy that strictly enforces
    /// `degree ≤ maxEdgesPerNode` for every node; the alternative
    /// "kept-if-in-top-K-for-either-endpoint" rule lets popular hubs
    /// retain every incident edge.
    ///
    /// Tie-break on equal weights is lexicographic over `(from, to)` so the
    /// pruned set is deterministic across runs.
    static func mergeAndCap(
        tagEdges: [MemoryGraphEdgeDTO],
        semanticEdges: [MemoryGraphEdgeDTO],
        maxEdgesPerNode: Int,
    ) -> [MemoryGraphEdgeDTO] {
        var byPair: [PairKey: MemoryGraphEdgeDTO] = [:]
        for edge in tagEdges {
            byPair[PairKey(edge)] = edge
        }
        for edge in semanticEdges where byPair[PairKey(edge)] == nil {
            byPair[PairKey(edge)] = edge
        }

        let ordered = byPair.values.sorted { a, b in
            if a.weight != b.weight { return a.weight > b.weight }
            if a.from != b.from { return a.from.uuidString < b.from.uuidString }
            return a.to.uuidString < b.to.uuidString
        }
        var degree: [UUID: Int] = [:]
        var kept: [MemoryGraphEdgeDTO] = []
        kept.reserveCapacity(ordered.count)
        for edge in ordered {
            let dFrom = degree[edge.from, default: 0]
            let dTo = degree[edge.to, default: 0]
            guard dFrom < maxEdgesPerNode, dTo < maxEdgesPerNode else { continue }
            kept.append(edge)
            degree[edge.from] = dFrom + 1
            degree[edge.to] = dTo + 1
        }
        return kept
    }

    // MARK: - Helpers

    private static func titleFromContent(_ content: String) -> String {
        let firstLine = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? content
        if firstLine.count <= 60 { return firstLine }
        let idx = firstLine.index(firstLine.startIndex, offsetBy: 60)
        return String(firstLine[..<idx]) + "…"
    }

    /// PostgreSQL `uuid[]` literal. Inputs are `UUID` so there is no injection
    /// surface; spliced via `unsafeRaw` because SQLKit has no encoder for the
    /// uuid array type (same reason `formatTextArray` exists in MemoryRepository).
    static func formatUUIDArray(_ ids: [UUID]) -> String {
        "ARRAY[" + ids.map { "'\($0.uuidString)'" }.joined(separator: ",") + "]::uuid[]"
    }

    /// Undirected pair key — invariant that `from < to`. Edges are produced
    /// with this invariant by the SQL (`a.id < b.id` for tags;
    /// `LEAST/GREATEST` for semantic), so equality on `(from, to)` is enough.
    private struct PairKey: Hashable {
        let from: UUID
        let to: UUID
        init(_ edge: MemoryGraphEdgeDTO) {
            from = edge.from; to = edge.to
        }
    }
}

// MARK: - Row decoders

private struct NodeRow: Decodable {
    let id: UUID
    let content: String
    let tags: [String]?
    let created_at: Date?
    let score: Double
}

private struct TagEdgeRow: Decodable {
    let from_id: UUID
    let to_id: UUID
    let tag: String
}

private struct SemanticEdgeRow: Decodable {
    let from_id: UUID
    let to_id: UUID
    let similarity: Double
}
