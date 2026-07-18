@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import SQLKit
import Testing

/// Backs the agentic `vault_map` tool + opt-in `session_search` Space scoping.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct SpaceTopologyTests {
    private static func makeTenant(on fluent: Fluent) async throws -> UUID {
        let id = UUID()
        let user = User(
            id: id,
            email: "topo-\(UUID().uuidString.prefix(8).lowercased())@test.luminavault",
            username: "topo-\(UUID().uuidString.prefix(6).lowercased())",
            passwordHash: "stub"
        )
        try await user.save(on: fluent.db())
        // M90 repointed `spaces.tenant_id` → `vaults(id)`; the personal vault
        // id matches the user id. Seed it so Space inserts satisfy the FK.
        if let sql = fluent.db() as? any SQLDatabase {
            try await sql.raw("""
            INSERT INTO vaults (id, personal_owner_user_id, name, created_at, updated_at)
            VALUES (\(bind: id), \(bind: id), 'Test Vault', NOW(), NOW())
            ON CONFLICT (id) DO NOTHING
            """).run()
        }
        return id
    }

    @Test
    func `spaceTopology sorts by note count desc and resolves slug`() async throws {
        try await withTestFluent(label: "lv.test.space.topology") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let tenantID = try await Self.makeTenant(on: fluent)

            try await Space(tenantID: tenantID, name: "AI", slug: "ai", noteCount: 42).save(on: fluent.db())
            try await Space(tenantID: tenantID, name: "Stocks", slug: "stocks", noteCount: 17).save(on: fluent.db())
            try await Space(tenantID: tenantID, name: "Health", slug: "health", noteCount: 9).save(on: fluent.db())

            let repo = MemoryRepository(fluent: fluent)
            let topo = try await repo.spaceTopology(tenantID: tenantID)

            #expect(topo.map(\.slug) == ["ai", "stocks", "health"])
            #expect(topo.first?.noteCount == 42)

            // slug → id resolution (the session_search scoping path).
            let stocksID = topo.first { $0.slug == "stocks" }?.id
            #expect(stocksID != nil)
            #expect(topo.first { $0.slug == "nonexistent" }?.id == nil)
        }
    }

    @Test
    func `spaceTopology is tenant scoped`() async throws {
        try await withTestFluent(label: "lv.test.space.topology.tenant") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let a = try await Self.makeTenant(on: fluent)
            let b = try await Self.makeTenant(on: fluent)
            try await Space(tenantID: a, name: "AI", slug: "ai", noteCount: 1).save(on: fluent.db())

            let repo = MemoryRepository(fluent: fluent)
            #expect(try await repo.spaceTopology(tenantID: a).count == 1)
            #expect(try await repo.spaceTopology(tenantID: b).isEmpty)
        }
    }
}
