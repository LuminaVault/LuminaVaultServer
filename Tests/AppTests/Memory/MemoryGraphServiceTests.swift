@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// HER-235 — service-level tests for `MemoryGraphService`. Drives
/// `MemoryRepository.create` directly so the SQL derivation paths
/// (tag self-join + pgvector cosine + edge cap) can be exercised without
/// going through the HTTP layer. The controller surface is covered by
/// `MemoryGraphControllerTests`.
///
/// Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct MemoryGraphServiceTests {
    /// Embedding dimensionality matches the pgvector column (1536).
    private static let dim = 1536

    /// Returns a vector with a single 1.0 at `axis` and zeros elsewhere.
    /// Two basis vectors on different axes have cosine similarity 0.0;
    /// two on the same axis have similarity 1.0. Used to keep similarity
    /// arithmetic exact (no floating-point drift) across tests.
    private static func basis(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[axis] = 1
        return v
    }

    /// Vector at 45° between `axisA` and `axisB`. Cosine similarity with
    /// `basis(axisA)` is `sqrt(2)/2 ≈ 0.7071` — high enough to clear a 0.7
    /// threshold and low enough to be pruned by 0.8.
    private static func midpoint(_ axisA: Int, _ axisB: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        let component = Float(sqrt(2.0) / 2.0)
        v[axisA] = component
        v[axisB] = component
        return v
    }

    /// `memories.tenant_id` has an ON DELETE CASCADE FK to `users.id`
    /// (M06_CreateMemory). Tests can't fabricate a random UUID — the row
    /// must reference a real user. The HTTP register flow is the cheapest
    /// way to provision one + get its id back through the JWT claim.
    private static func decodeAuth(_ buf: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buf))
    }

    private static func registerAndAuth(client: some TestClientProtocol) async throws -> UUID {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(string: #"{"email":"graph-\#(suffix)@test.luminavault","username":"graph\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#)
        let resp = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body,
        ) { try Self.decodeAuth($0.body) }
        return resp.userId
    }

    @Test
    func `empty graph returned for tenant with no memories`() async throws {
        let tenant = UUID()
        try await withTestFluent(label: "test.graph.empty") { fluent in
            let svc = MemoryGraphService(fluent: fluent)
            let graph = try await svc.graph(
                tenantID: tenant,
                limit: 100,
                similarity: 0.5,
                maxEdgesPerNode: 5,
            )
            #expect(graph.nodes.isEmpty)
            #expect(graph.edges.isEmpty)
        }
    }

    @Test
    func `shared tag produces a tag edge`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tenant = try await Self.registerAndAuth(client: client)
            try await withTestFluent(label: "test.graph.tag") { fluent in
                let repo = MemoryRepository(fluent: fluent)
                // A and B share `swift`. C is unrelated. Basis vectors on
                // disjoint axes have cosine similarity 0 so no semantic
                // edges leak into the assertion.
                let memA = try await repo.create(tenantID: tenant, content: "A", embedding: Self.basis(0), tags: ["swift", "ios"])
                let memB = try await repo.create(tenantID: tenant, content: "B", embedding: Self.basis(100), tags: ["swift", "server"])
                _ = try await repo.create(tenantID: tenant, content: "C", embedding: Self.basis(200), tags: ["python"])

                let svc = MemoryGraphService(fluent: fluent)
                let graph = try await svc.graph(
                    tenantID: tenant,
                    limit: 100,
                    similarity: 0.99,
                    maxEdgesPerNode: 5,
                )
                #expect(graph.nodes.count == 3)
                let tagEdges = graph.edges.filter { $0.kind == .tag }
                #expect(tagEdges.count == 1)
                let edge = try #require(tagEdges.first)
                let endpoints = Set([edge.from, edge.to])
                #expect(try endpoints == Set([memA.requireID(), memB.requireID()]))
                #expect(edge.tag == "swift")
                #expect(edge.weight == 1.0)
            }
        }
    }

    @Test
    func `semantic similarity edge respects threshold`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tenant = try await Self.registerAndAuth(client: client)
            try await withTestFluent(label: "test.graph.semantic") { fluent in
                let repo = MemoryRepository(fluent: fluent)
                // A and B identical → similarity 1.0. A↔C at 45° → ≈ 0.7071.
                // Threshold 0.8 leaves only the A↔B edge surviving.
                let memA = try await repo.create(tenantID: tenant, content: "A", embedding: Self.basis(0))
                let memB = try await repo.create(tenantID: tenant, content: "B", embedding: Self.basis(0))
                _ = try await repo.create(tenantID: tenant, content: "C", embedding: Self.midpoint(0, 1))

                let svc = MemoryGraphService(fluent: fluent)
                let graph = try await svc.graph(
                    tenantID: tenant,
                    limit: 100,
                    similarity: 0.8,
                    maxEdgesPerNode: 5,
                )
                let semanticEdges = graph.edges.filter { $0.kind == .semantic }
                #expect(semanticEdges.count == 1)
                let edge = try #require(semanticEdges.first)
                let endpoints = Set([edge.from, edge.to])
                #expect(try endpoints == Set([memA.requireID(), memB.requireID()]))
                let sim = try #require(edge.similarity)
                #expect(sim > 0.99)
            }
        }
    }

    @Test
    func `per-node edge cap prunes excess edges`() throws {
        // Pure unit test of the cap algorithm — does not hit Postgres so the
        // Swift 6.3 frontend's region-analysis crash on closure-captured
        // `repo` (reproducible in this file's other DB-driven tests if any
        // loop or array-of-models construct is added inside `withTestFluent`)
        // is sidestepped entirely. The SQL paths for tag + semantic edge
        // production are already exercised by the other tests in this suite;
        // pruning is a pure-data transform and is verified here in isolation.
        let n0 = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        let n1 = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let n2 = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let n3 = try #require(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))

        /// All pairs (n0,n1), (n0,n2), (n0,n3), (n1,n2), (n1,n3), (n2,n3) with
        /// identical 1.0 similarity. With cap=2 every node must end up with
        /// degree ≤ 2 in the pruned set.
        func edge(_ a: UUID, _ b: UUID, weight: Double = 1.0) -> MemoryGraphEdgeDTO {
            MemoryGraphEdgeDTO(from: a, to: b, kind: .semantic, tag: nil, similarity: weight, weight: weight)
        }
        let candidates = [
            edge(n0, n1), edge(n0, n2), edge(n0, n3),
            edge(n1, n2), edge(n1, n3), edge(n2, n3),
        ]
        let pruned = MemoryGraphService.mergeAndCap(
            groupsInPrecedence: [candidates],
            maxEdgesPerNode: 2,
        )
        var degree: [UUID: Int] = [:]
        for e in pruned {
            degree[e.from, default: 0] += 1
            degree[e.to, default: 0] += 1
        }
        for (_, d) in degree {
            #expect(d <= 2, "per-node cap violated: degree=\(d)")
        }
        // 4 nodes, cap=2 → at most 4 surviving edges (4 × 2 / 2).
        #expect(pruned.count <= 4)
    }

    @Test
    func `lineage edges link a memory to its source page only when the page is in the node set`() throws {
        let mem = try #require(UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001"))
        let page = try #require(UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000002"))
        let orphanSource = try #require(UUID(uuidString: "cccccccc-0000-0000-0000-000000000003"))

        func row(_ id: UUID, source: UUID?) -> MemoryNodeRow {
            MemoryNodeRow(
                id: id, content: "c", tags: nil, created_at: Date(), score: 1,
                space_id: nil, source_vault_file_id: source,
            )
        }
        let rows = [row(mem, source: page), row(orphanSource, source: orphanSource)]
        // Only `page` is an included wiki node; the orphan's source is not.
        let edges = MemoryGraphService.lineageEdges(memRows: rows, wikiIDs: [page])

        #expect(edges.count == 1)
        let edge = try #require(edges.first)
        #expect(edge.kind == .wikilink)
        #expect(edge.weight == 1.0)
        #expect(Set([edge.from, edge.to]) == Set([mem, page]))
        #expect(edge.from.uuidString < edge.to.uuidString) // undirected invariant
    }

    @Test
    func `chain edges connect consecutive nodes within a group`() throws {
        let s1 = try #require(UUID(uuidString: "10000000-0000-0000-0000-000000000000"))
        let nodes = (0 ..< 4).map { i in
            MemoryGraphService.NodeMeta(
                id: UUID(), spaceID: s1, createdAt: Date(timeIntervalSince1970: Double(i) * 1000),
            )
        } + [
            // A lone node in its own Space contributes no edge.
            MemoryGraphService.NodeMeta(id: UUID(), spaceID: UUID(), createdAt: Date()),
        ]
        let edges = MemoryGraphService.chainEdges(
            grouping: nodes, by: { $0.spaceID.map(MemoryGraphService.AnyGroupKey.uuid) },
            kind: .space, weight: 0.45,
        )
        // 4-node group → a 3-edge chain; the singleton group adds nothing.
        #expect(edges.count == 3)
        #expect(edges.allSatisfy { $0.kind == .space && $0.weight == 0.45 })
        #expect(edges.allSatisfy { $0.from.uuidString < $0.to.uuidString })
    }

    @Test
    func `merge precedence keeps the explicit wikilink over a weaker inferred edge on the same pair`() throws {
        let a = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1"))
        let b = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000b2"))
        let (from, to) = MemoryGraphService.ordered(a, b)
        let wikilink = MemoryGraphEdgeDTO(from: from, to: to, kind: .wikilink, tag: nil, similarity: nil, weight: 1.0)
        let temporal = MemoryGraphEdgeDTO(from: from, to: to, kind: .temporal, tag: nil, similarity: nil, weight: 0.3)

        // temporal listed first by array position, but wikilink has higher
        // precedence (earlier group) so it must win the dedupe.
        let merged = MemoryGraphService.mergeAndCap(
            groupsInPrecedence: [[wikilink], [temporal]],
            maxEdgesPerNode: 8,
        )
        #expect(merged.count == 1)
        #expect(merged.first?.kind == .wikilink)
    }

    @Test
    func `tenant isolation excludes other tenants' memories`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let tenantA = try await Self.registerAndAuth(client: client)
            let tenantB = try await Self.registerAndAuth(client: client)
            try await withTestFluent(label: "test.graph.isolation") { fluent in
                let repo = MemoryRepository(fluent: fluent)
                // Identical content / vectors / tags across tenants. Tenant A's
                // graph must contain only tenant A's nodes — no edges may
                // cross the tenant boundary even when similarity would
                // otherwise match.
                _ = try await repo.create(tenantID: tenantA, content: "A1", embedding: Self.basis(0), tags: ["shared"])
                _ = try await repo.create(tenantID: tenantA, content: "A2", embedding: Self.basis(0), tags: ["shared"])
                _ = try await repo.create(tenantID: tenantB, content: "B1", embedding: Self.basis(0), tags: ["shared"])

                let svc = MemoryGraphService(fluent: fluent)
                let graphA = try await svc.graph(
                    tenantID: tenantA,
                    limit: 100,
                    similarity: 0.5,
                    maxEdgesPerNode: 5,
                )
                #expect(graphA.nodes.count == 2)
                let nodeIDs = Set(graphA.nodes.map(\.id))
                for edge in graphA.edges {
                    #expect(nodeIDs.contains(edge.from))
                    #expect(nodeIDs.contains(edge.to))
                }
            }
        }
    }
}
