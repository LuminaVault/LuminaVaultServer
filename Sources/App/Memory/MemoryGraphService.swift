import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared
import SQLKit

/// HER-235 — derives a tenant-scoped second-brain graph on read.
///
/// Nodes are **memories** (recall layer) and, when requested, **wiki pages**
/// (one per `vault_files` row — the same source pages the compile pipeline
/// writes to `wiki/sources/<slug>.md`). Edges are derived on read:
///
///   - `wikilink`  — `memory.source_vault_file_id` → its source page. The
///                   explicit lineage link the wiki export renders as the
///                   `[[Source file]]` backlink. Strongest signal.
///   - `tag`       — memories sharing ≥1 tag.
///   - `space`     — nodes filed under the same Space (memories + pages).
///   - `semantic`  — pgvector cosine neighbours among memories.
///   - `temporal`  — nodes captured in the same day bucket.
///
/// v1 ships **no persistence**: everything is computed from existing rows
/// (`memories`, `vault_files`). A later iteration can materialise a
/// `graph_edges` table at compile time without changing this contract.
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

    /// All edge kinds, used as the default when the caller doesn't filter.
    static let allEdgeKinds: Set<MemoryEdgeKindDTO> = [.wikilink, .tag, .space, .semantic, .temporal]

    // Fixed weights for the binary / structural edge kinds. Semantic keeps
    // its cosine similarity as weight; these are constants chosen so the
    // visual hierarchy reads wikilink > tag > space > temporal.
    // Weight drives only visual alpha/thickness; capping priority is handled
    // separately by edge-kind precedence in `mergeAndCap`. Tag overlap is a
    // strong binary signal, so it keeps weight 1.0 alongside wikilink.
    private static let wikilinkWeight = 1.0
    private static let tagWeight = 1.0
    private static let spaceWeight = 0.45
    private static let temporalWeight = 0.30

    /// Wiki pages have no `score`; render them at a modest constant size.
    private static let wikiNodeScore = 1.0

    /// Space hubs render large; the client also styles `.space` distinctly, so
    /// this is mostly a fallback size signal.
    private static let spaceHubScore = 8.0

    /// Computes the derived graph for `tenantID`.
    ///
    /// - Parameters:
    ///   - limit: Max nodes returned **per source** (memories, and pages).
    ///   - similarity: Floor for cosine similarity edges (1 − pgvector `<=>`).
    ///   - maxEdgesPerNode: Per-node cap after all edge kinds merge.
    ///   - includeWikiPages: When true, `vault_files` are added as wiki-page nodes.
    ///   - kinds: Which edge kinds to compute. Defaults to all.
    func graph(
        tenantID: UUID,
        limit: Int,
        similarity: Double,
        maxEdgesPerNode: Int,
        includeWikiPages: Bool = true,
        kinds: Set<MemoryEdgeKindDTO> = MemoryGraphService.allEdgeKinds
    ) async throws -> MemoryGraphResponse {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for graph query")
        }

        let memRows = try await fetchMemoryNodes(sql: sql, tenantID: tenantID, limit: limit)
        let wikiRows = includeWikiPages
            ? try await fetchWikiNodes(sql: sql, tenantID: tenantID, limit: limit)
            : []
        guard !memRows.isEmpty || !wikiRows.isEmpty else {
            return MemoryGraphResponse(nodes: [], edges: [], generatedAt: Date())
        }

        let memoryIDs = memRows.map(\.id)
        let wikiIDSet = Set(wikiRows.map(\.id))

        // Combined node metadata used by the Swift-side edge builders.
        let nodeMeta: [NodeMeta] =
            memRows.map { NodeMeta(id: $0.id, spaceID: $0.space_id, createdAt: $0.created_at) }
                + wikiRows.map { NodeMeta(id: $0.id, spaceID: $0.space_id, createdAt: $0.created_at) }

        // SQL-derived edges (memories only — pages have no tags column / embedding).
        async let tagEdgesTask: [MemoryGraphEdgeDTO] = kinds.contains(.tag) && !memoryIDs.isEmpty
            ? computeTagEdges(sql: sql, tenantID: tenantID, ids: memoryIDs)
            : []
        async let semanticEdgesTask: [MemoryGraphEdgeDTO] = kinds.contains(.semantic) && !memoryIDs.isEmpty
            ? computeSemanticEdges(
                sql: sql,
                tenantID: tenantID,
                ids: memoryIDs,
                similarity: similarity,
                maxEdgesPerNode: maxEdgesPerNode
            )
            : []
        let tagEdges = try await tagEdgesTask
        let semanticEdges = try await semanticEdgesTask

        // Swift-derived edges from the fetched metadata (no extra round-trips).
        let wikilinkEdges = kinds.contains(.wikilink)
            ? Self.lineageEdges(memRows: memRows, wikiIDs: wikiIDSet)
            : []
        let temporalEdges = kinds.contains(.temporal)
            ? Self.chainEdges(grouping: nodeMeta, by: { $0.createdAt.map { AnyGroupKey.day(Int($0.timeIntervalSince1970 / 86400)) } }, kind: .temporal, weight: Self.temporalWeight)
            : []

        // Space hubs: a synthetic `.space` node per Space that has ≥1 member in
        // the current node set, with `.space` **star** edges from the hub to
        // each member. Replaces the old space "chain" — a hub reads as a real
        // cluster centre. Hubs are exempt from the per-node edge cap so they
        // connect to all their members.
        var spaceNodes: [MemoryGraphNodeDTO] = []
        var spaceEdges: [MemoryGraphEdgeDTO] = []
        var hubIDs: Set<UUID> = []
        if kinds.contains(.space) {
            let memberSpaceIDs = Array(Set(nodeMeta.compactMap(\.spaceID)))
            if !memberSpaceIDs.isEmpty {
                let names = try await fetchSpaceNames(sql: sql, tenantID: tenantID, ids: memberSpaceIDs)
                hubIDs = Set(names.keys)
                spaceNodes = names.map { id, name in
                    MemoryGraphNodeDTO(
                        id: id, title: name, tags: [],
                        createdAt: Date(timeIntervalSince1970: 0),
                        score: Self.spaceHubScore, kind: .space, spaceID: id
                    )
                }
                spaceEdges = Self.spaceStarEdges(nodeMeta: nodeMeta, hubIDs: hubIDs, weight: Self.spaceWeight)
            }
        }

        let merged = Self.mergeAndCap(
            groupsInPrecedence: [wikilinkEdges, tagEdges, spaceEdges, semanticEdges, temporalEdges],
            maxEdgesPerNode: maxEdgesPerNode,
            uncapped: hubIDs
        )

        let now = Date()
        let memoryNodes = memRows.map { row in
            MemoryGraphNodeDTO(
                id: row.id,
                title: Self.titleFromContent(row.content),
                tags: row.tags ?? [],
                createdAt: row.created_at ?? Date(timeIntervalSince1970: 0),
                score: row.score,
                kind: .memory,
                spaceID: row.space_id,
                activity: Self.activity(score: row.score, lastAccessed: row.last_accessed_at ?? row.created_at, now: now),
                position: Self.position(x: row.graph_x, y: row.graph_y, z: row.graph_z)
            )
        }
        let wikiNodes = wikiRows.map { row in
            MemoryGraphNodeDTO(
                id: row.id,
                title: Self.titleFromWiki(title: row.title, path: row.path),
                tags: [],
                createdAt: row.created_at ?? Date(timeIntervalSince1970: 0),
                score: Self.wikiNodeScore,
                kind: .wikiPage,
                spaceID: row.space_id
            )
        }
        return MemoryGraphResponse(nodes: memoryNodes + wikiNodes + spaceNodes, edges: merged, generatedAt: Date())
    }

    // MARK: - Node selection

    private func fetchMemoryNodes(sql: any SQLDatabase, tenantID: UUID, limit: Int) async throws -> [MemoryNodeRow] {
        try await sql.raw("""
        SELECT id, content, tags, created_at, score, space_id, source_vault_file_id,
               last_accessed_at, graph_x, graph_y, graph_z
        FROM memories
        WHERE tenant_id = \(bind: tenantID)
        ORDER BY score DESC, last_accessed_at DESC NULLS LAST, id ASC
        LIMIT \(bind: limit)
        """).all(decoding: MemoryNodeRow.self)
    }

    /// Source nodes — one per captured `vault_files` row. Includes text-like
    /// captures (notes, saved links → `text/markdown`) **and images**
    /// (`image/*`, e.g. screenshots and photo captures). Images were
    /// previously excluded by a `text/%`-only filter, so they never appeared
    /// on the graph despite being first-class captures.
    private func fetchWikiNodes(sql: any SQLDatabase, tenantID: UUID, limit: Int) async throws -> [WikiNodeRow] {
        try await sql.raw("""
        SELECT id,
               path,
               metadata->>'title' AS title,
               space_id,
               created_at
        FROM vault_files
        WHERE tenant_id = \(bind: tenantID)
          AND (content_type LIKE 'text/%' OR content_type LIKE 'image/%')
        ORDER BY created_at DESC NULLS LAST, id ASC
        LIMIT \(bind: limit)
        """).all(decoding: WikiNodeRow.self)
    }

    /// Space names for the given ids — drives the hub node titles.
    private func fetchSpaceNames(sql: any SQLDatabase, tenantID: UUID, ids: [UUID]) async throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        struct Row: Decodable { let id: UUID; let name: String }
        let rows = try await sql.raw("""
        SELECT id, name FROM spaces
        WHERE tenant_id = \(bind: tenantID) AND id = ANY(\(unsafeRaw: Self.formatUUIDArray(ids)))
        """).all(decoding: Row.self)
        return Dictionary(rows.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Space hub (star) edges

    /// One edge from each member node to its Space hub (hub id = Space UUID).
    /// Undirected, deduped by `ordered`. Members with no Space, or whose Space
    /// has no hub in the current set, are skipped.
    static func spaceStarEdges(nodeMeta: [NodeMeta], hubIDs: Set<UUID>, weight: Double) -> [MemoryGraphEdgeDTO] {
        nodeMeta.compactMap { n -> MemoryGraphEdgeDTO? in
            guard let space = n.spaceID, hubIDs.contains(space) else { return nil }
            let (from, to) = ordered(n.id, space)
            return MemoryGraphEdgeDTO(
                from: from, to: to, kind: .space,
                tag: nil, similarity: nil, weight: weight
            )
        }
    }

    // MARK: - Tag edges

    /// One edge per pair that shares ≥1 tag. The shared tag chosen is the
    /// lexicographically smallest (`min(tag)`) so the result is deterministic
    /// across runs.
    private func computeTagEdges(
        sql: any SQLDatabase,
        tenantID: UUID,
        ids: [UUID]
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
                weight: Self.tagWeight
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
        maxEdgesPerNode: Int
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
                weight: $0.similarity
            )
        }
    }

    // MARK: - Lineage (wikilink) edges

    /// A memory → its source page. This is the explicit, human-meaningful
    /// link the wiki export renders as `[[Source file]]`. Emitted only when
    /// the source page is in the current node set (an included wiki node).
    static func lineageEdges(memRows: [MemoryNodeRow], wikiIDs: Set<UUID>) -> [MemoryGraphEdgeDTO] {
        memRows.compactMap { row -> MemoryGraphEdgeDTO? in
            guard let source = row.source_vault_file_id, wikiIDs.contains(source) else { return nil }
            let (from, to) = Self.ordered(row.id, source)
            return MemoryGraphEdgeDTO(
                from: from, to: to, kind: .wikilink,
                tag: nil, similarity: nil, weight: Self.wikilinkWeight
            )
        }
    }

    // MARK: - Chain edges (space / temporal)

    /// Builds a light "chain" of edges within each group: nodes are sorted by
    /// `(createdAt, id)` and consecutive nodes are linked. This gives each
    /// Space / day-bucket visual cohesion in O(n) edges rather than the
    /// O(n²) hairball a full clique would produce. Deterministic across runs.
    static func chainEdges(
        grouping nodes: [NodeMeta],
        by key: (NodeMeta) -> AnyGroupKey?,
        kind: MemoryEdgeKindDTO,
        weight: Double
    ) -> [MemoryGraphEdgeDTO] {
        var buckets: [AnyGroupKey: [NodeMeta]] = [:]
        for node in nodes {
            guard let k = key(node) else { continue }
            buckets[k, default: []].append(node)
        }
        var edges: [MemoryGraphEdgeDTO] = []
        for (_, members) in buckets where members.count >= 2 {
            let sorted = members.sorted { a, b in
                let da = a.createdAt ?? Date(timeIntervalSince1970: 0)
                let db = b.createdAt ?? Date(timeIntervalSince1970: 0)
                if da != db { return da > db }
                return a.id.uuidString < b.id.uuidString
            }
            for i in 0 ..< (sorted.count - 1) {
                let (from, to) = ordered(sorted[i].id, sorted[i + 1].id)
                edges.append(MemoryGraphEdgeDTO(
                    from: from, to: to, kind: kind,
                    tag: nil, similarity: nil, weight: weight
                ))
            }
        }
        return edges
    }

    // MARK: - Merge + cap

    /// Combines all edge kinds, deduping by undirected pair with **precedence**
    /// (the first group an edge appears in wins — explicit signals beat
    /// inferred ones), then prunes greedily so every node keeps
    /// `degree ≤ maxEdgesPerNode`. Capping order is `(precedence, weight DESC)`
    /// so an explicit `wikilink` is never dropped in favour of a weaker
    /// inferred edge. Tie-break is lexicographic over `(from, to)` for
    /// determinism.
    ///
    /// `groupsInPrecedence` must be ordered strongest-first, e.g.
    /// `[wikilink, tag, space, semantic, temporal]`.
    static func mergeAndCap(
        groupsInPrecedence groups: [[MemoryGraphEdgeDTO]],
        maxEdgesPerNode: Int,
        uncapped: Set<UUID> = []
    ) -> [MemoryGraphEdgeDTO] {
        var byPair: [PairKey: (rank: Int, edge: MemoryGraphEdgeDTO)] = [:]
        for (rank, group) in groups.enumerated() {
            for edge in group where byPair[PairKey(edge)] == nil {
                byPair[PairKey(edge)] = (rank, edge)
            }
        }

        let ordered = byPair.values.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.edge.weight != b.edge.weight { return a.edge.weight > b.edge.weight }
            if a.edge.from != b.edge.from { return a.edge.from.uuidString < b.edge.from.uuidString }
            return a.edge.to.uuidString < b.edge.to.uuidString
        }
        var degree: [UUID: Int] = [:]
        var kept: [MemoryGraphEdgeDTO] = []
        kept.reserveCapacity(ordered.count)
        for entry in ordered {
            let edge = entry.edge
            // Hubs (`uncapped`, e.g. Space nodes) connect to all members; the
            // cap still applies to the non-hub endpoint.
            let fromOK = uncapped.contains(edge.from) || degree[edge.from, default: 0] < maxEdgesPerNode
            let toOK = uncapped.contains(edge.to) || degree[edge.to, default: 0] < maxEdgesPerNode
            guard fromOK, toOK else { continue }
            kept.append(edge)
            if !uncapped.contains(edge.from) { degree[edge.from, default: 0] += 1 }
            if !uncapped.contains(edge.to) { degree[edge.to, default: 0] += 1 }
        }
        return kept
    }

    // MARK: - Helpers

    private static func titleFromContent(_ content: String) -> String {
        let raw = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? content
        // Strip leading markdown markers (#, >, -, *, whitespace) so titles read
        // clean (e.g. "KB Healthcheck Report", not "# KB Healthcheck Report").
        var firstLine = String(raw.drop(while: { "#>-* \t".contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        if firstLine.isEmpty { firstLine = raw.trimmingCharacters(in: .whitespaces) }
        if firstLine.count <= 60 { return firstLine }
        let idx = firstLine.index(firstLine.startIndex, offsetBy: 60)
        return String(firstLine[..<idx]) + "…"
    }

    /// HER-235 3D viz — node activity/heat in `[0, 1]`. Blends recency of last
    /// access (fresher → hotter, over a 90-day window) with a log-normalized
    /// score, so both "recently touched" and "important" nodes read hot on the
    /// cyan→amber ramp. Deterministic given `now`.
    static func activity(score: Double, lastAccessed: Date?, now: Date) -> Double {
        let scoreNorm = min(1.0, max(0.0, log1p(max(0, score)) / log1p(100.0)))
        let recency: Double
        if let lastAccessed {
            let ageDays = now.timeIntervalSince(lastAccessed) / 86_400.0
            recency = min(1.0, max(0.0, 1.0 - ageDays / 90.0))
        } else {
            recency = 0.0
        }
        return min(1.0, max(0.0, 0.6 * recency + 0.4 * scoreNorm))
    }

    /// HER-235 3D viz — assembles a `GraphPosition3D` only when all three
    /// persisted coords are present; a partially-laid-out row returns `nil` so
    /// the client force-directs it rather than snapping it to the origin.
    static func position(x: Double?, y: Double?, z: Double?) -> GraphPosition3D? {
        guard let x, let y, let z else { return nil }
        return GraphPosition3D(x: x, y: y, z: z)
    }

    /// Wiki-page title: prefer the metadata title, else the file's basename
    /// (sans extension), else the raw path.
    private static func titleFromWiki(title: String?, path: String) -> String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        let base = (path as NSString).lastPathComponent
        let noExt = (base as NSString).deletingPathExtension
        return noExt.isEmpty ? path : noExt
    }

    /// Returns the pair `(from, to)` with the undirected invariant `from < to`
    /// (lexicographic on `uuidString`) so it matches `PairKey` equality.
    static func ordered(_ a: UUID, _ b: UUID) -> (UUID, UUID) {
        a.uuidString < b.uuidString ? (a, b) : (b, a)
    }

    /// PostgreSQL `uuid[]` literal. Inputs are `UUID` so there is no injection
    /// surface; spliced via `unsafeRaw` because SQLKit has no encoder for the
    /// uuid array type (same reason `formatTextArray` exists in MemoryRepository).
    static func formatUUIDArray(_ ids: [UUID]) -> String {
        "ARRAY[" + ids.map { "'\($0.uuidString)'" }.joined(separator: ",") + "]::uuid[]"
    }

    /// Undirected pair key — invariant that `from < to`. All edge producers
    /// use `ordered(_:_:)` / `LEAST`/`GREATEST`, so equality on `(from, to)`
    /// is enough.
    private struct PairKey: Hashable {
        let from: UUID
        let to: UUID
        init(_ edge: MemoryGraphEdgeDTO) {
            from = edge.from; to = edge.to
        }
    }

    /// Lightweight node metadata for the Swift-side chain builders.
    struct NodeMeta {
        let id: UUID
        let spaceID: UUID?
        let createdAt: Date?
    }

    /// Grouping key for `chainEdges` — either a Space id or a day bucket.
    enum AnyGroupKey: Hashable {
        case uuid(UUID)
        case day(Int)
    }
}

// MARK: - Row decoders

struct MemoryNodeRow: Decodable {
    let id: UUID
    let content: String
    let tags: [String]?
    let created_at: Date?
    let score: Double
    let space_id: UUID?
    let source_vault_file_id: UUID?
    // HER-235 3D viz — last access drives `activity`; graph_x/y/z are the
    // persisted PCA layout coords (nil until the layout worker has run).
    let last_accessed_at: Date?
    let graph_x: Double?
    let graph_y: Double?
    let graph_z: Double?
}

private struct WikiNodeRow: Decodable {
    let id: UUID
    let path: String
    let title: String?
    let space_id: UUID?
    let created_at: Date?
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
