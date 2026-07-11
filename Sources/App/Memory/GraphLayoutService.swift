import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import SQLKit

/// HER-235 3D viz — computes and persists a stable 3D layout coordinate for a
/// tenant's memories by reducing their 1536-d embeddings to 3 dimensions via
/// **PCA (top-3 principal components, NIPALS/power-iteration)**.
///
/// Pure Swift, no Accelerate/LAPACK — portable to the Linux deploy target and
/// deterministic (fixed, data-derived seeding), so the same embeddings always
/// yield the same layout. Runs off the request path (see `GraphLayoutWorker`);
/// results are read back by `MemoryGraphService` into `MemoryGraphNodeDTO.position`.
struct GraphLayoutService {
    let fluent: Fluent
    var logger: Logger = .init(label: "lv.graph.layout")

    /// Cap on how many memories we lay out per tenant. Matches the graph
    /// endpoint's practical ceiling; the newest/highest-score memories win.
    static let maxLayoutNodes = 2000
    /// Half-extent of the normalized output cube. Coordinates land in
    /// `[-cubeExtent, +cubeExtent]` on each axis.
    static let cubeExtent = 60.0
    static let powerIterations = 64
    static let convergenceEpsilon = 1e-6

    /// Computes the 3D layout for `tenantID` and writes `graph_x/y/z` +
    /// `graph_layout_at`. Returns the number of memories laid out (0 if the
    /// tenant has fewer than 2 embedded memories — nothing to reduce).
    @discardableResult
    func computeAndPersist(tenantID: UUID) async throws -> Int {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for graph layout")
        }
        let rows = try await fetchEmbeddings(sql: sql, tenantID: tenantID)
        guard rows.count >= 2 else { return 0 }

        let ids = rows.map(\.id)
        let vectors = rows.map(\.vector)
        let coords = Self.projectTo3D(vectors)
        try await persist(sql: sql, tenantID: tenantID, ids: ids, coords: coords)
        logger.info("laid out \(ids.count) memories for tenant \(tenantID)")
        return ids.count
    }

    // MARK: - PCA (pure, unit-testable)

    /// Projects `vectors` (each same dimension `d`) onto their top-3 principal
    /// components and normalizes the result into the output cube. Returns one
    /// `(x, y, z)` per input row, in input order. Fewer than 3 usable components
    /// (e.g. only 2 rows) pad the missing axes with 0.
    static func projectTo3D(_ vectors: [[Double]]) -> [(x: Double, y: Double, z: Double)] {
        let n = vectors.count
        guard n >= 2, let d = vectors.first?.count, d > 0 else {
            return vectors.map { _ in (0, 0, 0) }
        }

        // Center the data: subtract the per-dimension mean.
        var mean = [Double](repeating: 0, count: d)
        for v in vectors {
            for j in 0 ..< d {
                mean[j] += v[j]
            }
        }
        for j in 0 ..< d {
            mean[j] /= Double(n)
        }
        var x = vectors.map { row -> [Double] in
            var r = row
            for j in 0 ..< d {
                r[j] -= mean[j]
            }
            return r
        }

        // NIPALS: extract up to 3 components, deflating X after each.
        var scores = [[Double]](repeating: [Double](repeating: 0, count: 3), count: n)
        let components = min(3, min(n - 1, d))
        for k in 0 ..< components {
            var t = column(x, index: k % d, rows: n) // deterministic seed
            var p = [Double](repeating: 0, count: d)
            for _ in 0 ..< powerIterations {
                // p = Xᵀ t / (tᵀ t)
                let tt = dot(t, t)
                if tt < convergenceEpsilon { break }
                p = matTvec(x, t, rows: n, cols: d)
                for j in 0 ..< d {
                    p[j] /= tt
                }
                normalize(&p)
                // t_new = X p / (pᵀ p)   (pᵀp == 1 after normalize)
                let tNew = matVec(x, p, rows: n, cols: d)
                let delta = diffNorm(t, tNew)
                t = tNew
                if delta < convergenceEpsilon { break }
            }
            for i in 0 ..< n {
                scores[i][k] = t[i]
            }
            // Deflate: X = X - t pᵀ
            for i in 0 ..< n {
                let ti = t[i]
                if ti == 0 { continue }
                for j in 0 ..< d {
                    x[i][j] -= ti * p[j]
                }
            }
        }

        return normalizeToCube(scores)
    }

    /// Scales the 3 score axes independently into `[-cubeExtent, cubeExtent]`
    /// by peak absolute value per axis (preserves relative cluster shape while
    /// bounding the render volume). Zero-variance axes collapse to 0.
    static func normalizeToCube(_ scores: [[Double]]) -> [(x: Double, y: Double, z: Double)] {
        var maxAbs = [Double](repeating: 0, count: 3)
        for s in scores {
            for k in 0 ..< 3 {
                maxAbs[k] = max(maxAbs[k], abs(s[k]))
            }
        }
        let scale = maxAbs.map { $0 > 1e-9 ? cubeExtent / $0 : 0 }
        return scores.map { s in (x: s[0] * scale[0], y: s[1] * scale[1], z: s[2] * scale[2]) }
    }

    // MARK: - Small linear-algebra helpers

    private static func column(_ m: [[Double]], index: Int, rows: Int) -> [Double] {
        let j = m.first.map { index % max(1, $0.count) } ?? 0
        return (0 ..< rows).map { m[$0][j] }
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0; for i in 0 ..< a.count {
            s += a[i] * b[i]
        }; return s
    }

    /// Xᵀ · t  where X is rows×cols → length-cols vector.
    private static func matTvec(_ x: [[Double]], _ t: [Double], rows: Int, cols: Int) -> [Double] {
        var out = [Double](repeating: 0, count: cols)
        for i in 0 ..< rows {
            let ti = t[i]; if ti == 0 { continue }
            let row = x[i]
            for j in 0 ..< cols {
                out[j] += row[j] * ti
            }
        }
        return out
    }

    /// X · p  where X is rows×cols → length-rows vector.
    private static func matVec(_ x: [[Double]], _ p: [Double], rows: Int, cols: Int) -> [Double] {
        var out = [Double](repeating: 0, count: rows)
        for i in 0 ..< rows {
            var s = 0.0; let row = x[i]
            for j in 0 ..< cols {
                s += row[j] * p[j]
            }
            out[i] = s
        }
        return out
    }

    private static func normalize(_ v: inout [Double]) {
        let n = dot(v, v).squareRoot()
        if n > 1e-12 { for i in 0 ..< v.count {
            v[i] /= n
        } }
    }

    private static func diffNorm(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0; for i in 0 ..< a.count {
            let d = a[i] - b[i]; s += d * d
        }; return s.squareRoot()
    }

    // MARK: - DB I/O

    private struct EmbeddingRow: Decodable { let id: UUID; let embedding_text: String }
    struct LoadedEmbedding { let id: UUID; let vector: [Double] }

    private func fetchEmbeddings(sql: any SQLDatabase, tenantID: UUID) async throws -> [LoadedEmbedding] {
        // pgvector has no native SQLKit decoder → cast to text and parse the
        // `[a,b,c]` literal. Order by score so the layout ceiling keeps the
        // most-relevant memories when a tenant exceeds `maxLayoutNodes`.
        let rows = try await sql.raw("""
        SELECT id, embedding::text AS embedding_text
        FROM memories
        WHERE tenant_id = \(bind: tenantID) AND embedding IS NOT NULL
        ORDER BY score DESC, last_accessed_at DESC NULLS LAST, id ASC
        LIMIT \(bind: Self.maxLayoutNodes)
        """).all(decoding: EmbeddingRow.self)

        return rows.compactMap { row in
            let parsed = Self.parsePgVector(row.embedding_text)
            return parsed.isEmpty ? nil : LoadedEmbedding(id: row.id, vector: parsed)
        }
    }

    /// Parses a pgvector text literal `"[0.1,0.2,...]"` into `[Double]`.
    static func parsePgVector(_ text: String) -> [Double] {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] \n"))
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func persist(
        sql: any SQLDatabase,
        tenantID: UUID,
        ids: [UUID],
        coords: [(x: Double, y: Double, z: Double)]
    ) async throws {
        let now = Date()
        // Batch the UPDATEs via a VALUES join so a 2k-node layout is a handful
        // of round-trips, not 2k. All values are server-computed (UUIDs +
        // doubles) — no user input in the spliced literal.
        let batchSize = 250
        var index = 0
        while index < ids.count {
            let end = min(index + batchSize, ids.count)
            var values = SQLQueryString("")
            for i in index ..< end {
                if i > index { values += SQLQueryString(", ") }
                let c = coords[i]
                values += "(\(bind: ids[i])::uuid, \(bind: c.x)::double precision, \(bind: c.y)::double precision, \(bind: c.z)::double precision)"
            }
            try await sql.raw("""
            UPDATE memories AS m
            SET graph_x = v.x, graph_y = v.y, graph_z = v.z, graph_layout_at = \(bind: now)
            FROM (VALUES \(values)) AS v(id, x, y, z)
            WHERE m.id = v.id AND m.tenant_id = \(bind: tenantID)
            """).run()
            index = end
        }
    }
}
