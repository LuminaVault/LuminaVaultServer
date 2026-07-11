@testable import App
import Foundation
import Testing

/// HER-235 — pure PCA projection tests (no DB). Verify determinism, output
/// bounds, degenerate inputs, and that the reduction preserves separation
/// between two well-separated clusters.
struct GraphLayoutServiceTests {
    @Test
    func `projects to bounded cube`() {
        let vectors: [[Double]] = (0 ..< 50).map { i in
            let row: [Double] = (0 ..< 16).map { j in
                Double((i * 7 + j * 3) % 11) - 5.0
            }
            return row
        }
        let coords = GraphLayoutService.projectTo3D(vectors)
        #expect(coords.count == vectors.count)
        for c in coords {
            #expect(abs(c.x) <= GraphLayoutService.cubeExtent + 1e-6)
            #expect(abs(c.y) <= GraphLayoutService.cubeExtent + 1e-6)
            #expect(abs(c.z) <= GraphLayoutService.cubeExtent + 1e-6)
        }
    }

    @Test
    func `is deterministic for identical input`() {
        let vectors = (0 ..< 30).map { i in (0 ..< 12).map { j in sin(Double(i * 12 + j)) } }
        let a = GraphLayoutService.projectTo3D(vectors)
        let b = GraphLayoutService.projectTo3D(vectors)
        #expect(a.count == b.count)
        for i in 0 ..< a.count {
            #expect(a[i].x == b[i].x)
            #expect(a[i].y == b[i].y)
            #expect(a[i].z == b[i].z)
        }
    }

    @Test
    func `handles fewer than two rows`() {
        #expect(GraphLayoutService.projectTo3D([]).isEmpty)
        let one = GraphLayoutService.projectTo3D([[1, 2, 3]])
        #expect(one.count == 1)
        #expect(one[0].x == 0 && one[0].y == 0 && one[0].z == 0)
    }

    @Test
    func `separates two clusters along the principal axis`() {
        // Cluster A near origin, cluster B far along all dims. The top PC should
        // place them on opposite sides, so their mean x-coords differ.
        var vectors: [[Double]] = []
        for _ in 0 ..< 20 {
            vectors.append((0 ..< 8).map { _ in 0.0 })
        }
        for _ in 0 ..< 20 {
            vectors.append((0 ..< 8).map { _ in 10.0 })
        }
        let coords = GraphLayoutService.projectTo3D(vectors)
        let meanA = coords.prefix(20).map(\.x).reduce(0, +) / 20
        let meanB = coords.suffix(20).map(\.x).reduce(0, +) / 20
        #expect(abs(meanA - meanB) > 1.0)
    }

    @Test
    func `parses pgvector text literal`() {
        #expect(GraphLayoutService.parsePgVector("[1,2,3]") == [1, 2, 3])
        #expect(GraphLayoutService.parsePgVector("[0.5, -0.25, 4]") == [0.5, -0.25, 4])
        #expect(GraphLayoutService.parsePgVector("[]").isEmpty)
    }

    @Test
    func `activity blends recency and score`() {
        let now = Date()
        let fresh = MemoryGraphService.activity(score: 50, lastAccessed: now, now: now)
        let stale = MemoryGraphService.activity(score: 50, lastAccessed: now.addingTimeInterval(-120 * 86400), now: now)
        #expect(fresh > stale)
        #expect(fresh <= 1.0 && stale >= 0.0)
    }
}
