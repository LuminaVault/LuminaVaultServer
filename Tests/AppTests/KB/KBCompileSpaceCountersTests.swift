@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import SQLKit
import Testing

/// Verifies the M38 denormalised counters (`note_count`, `last_compiled_at`)
/// land correctly after `KBCompileService.refreshSpaceCounters`. We bypass
/// the agent loop by calling the helper directly — the goal is to assert
/// the SQL, not the LLM pipeline.
@Suite(.serialized)
struct KBCompileSpaceCountersTests {
    @Test
    func `refreshSpaceCounters writes note_count and last_compiled_at per space`() async throws {
        try await withTestFluent(label: "lv.test.kbcompile.counters.basic") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let db = fluent.db()

            let tenantID = try await seedUser(on: fluent)
            let spaceA = try await seedSpace(tenantID: tenantID, slug: Self.slug("a"), on: db)
            let spaceB = try await seedSpace(tenantID: tenantID, slug: Self.slug("b"), on: db)

            for index in 0 ..< 3 {
                try await seedVaultFile(tenantID: tenantID, spaceID: spaceA, index: index, on: db)
                try await seedVaultFile(tenantID: tenantID, spaceID: spaceB, index: index, on: db)
            }

            let service = makeService(fluent: fluent)
            let at = Date()
            try await service.refreshSpaceCounters(
                tenantID: tenantID,
                spaceIDs: [spaceA, spaceB],
                at: at,
            )

            let reloadedA = try #require(try await Space.find(spaceA, on: db))
            let reloadedB = try #require(try await Space.find(spaceB, on: db))
            #expect(reloadedA.noteCount == 3)
            #expect(reloadedB.noteCount == 3)
            #expect(reloadedA.lastCompiledAt != nil)
            #expect(reloadedB.lastCompiledAt != nil)
            #expect(abs(reloadedA.lastCompiledAt!.timeIntervalSince(at)) < 1)
            #expect(abs(reloadedB.lastCompiledAt!.timeIntervalSince(at)) < 1)
        }
    }

    @Test
    func `refreshSpaceCounters is tenant-scoped`() async throws {
        try await withTestFluent(label: "lv.test.kbcompile.counters.tenant") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let db = fluent.db()

            let tenantA = try await seedUser(on: fluent)
            let tenantB = try await seedUser(on: fluent)
            let spaceA = try await seedSpace(tenantID: tenantA, slug: Self.slug("ta"), on: db)
            let spaceB = try await seedSpace(tenantID: tenantB, slug: Self.slug("tb"), on: db)

            try await seedVaultFile(tenantID: tenantA, spaceID: spaceA, index: 0, on: db)
            try await seedVaultFile(tenantID: tenantB, spaceID: spaceB, index: 0, on: db)

            let service = makeService(fluent: fluent)
            try await service.refreshSpaceCounters(
                tenantID: tenantA,
                spaceIDs: [spaceA, spaceB],
                at: Date(),
            )

            let reloadedA = try #require(try await Space.find(spaceA, on: db))
            let reloadedB = try #require(try await Space.find(spaceB, on: db))
            #expect(reloadedA.noteCount == 1)
            #expect(reloadedA.lastCompiledAt != nil)
            // tenantB's space is untouched — tenant scope holds.
            #expect(reloadedB.noteCount == 0)
            #expect(reloadedB.lastCompiledAt == nil)
        }
    }

    @Test
    func `refreshSpaceCounters resets note_count to live count`() async throws {
        try await withTestFluent(label: "lv.test.kbcompile.counters.self-heal") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let db = fluent.db()

            let tenantID = try await seedUser(on: fluent)
            let space = try await seedSpace(tenantID: tenantID, slug: Self.slug("h"), on: db)

            // Seed a wrong cached note_count via direct write.
            let row = try #require(try await Space.find(space, on: db))
            row.noteCount = 999
            try await row.save(on: db)

            try await seedVaultFile(tenantID: tenantID, spaceID: space, index: 0, on: db)
            try await seedVaultFile(tenantID: tenantID, spaceID: space, index: 1, on: db)

            let service = makeService(fluent: fluent)
            try await service.refreshSpaceCounters(
                tenantID: tenantID,
                spaceIDs: [space],
                at: Date(),
            )

            let reloaded = try #require(try await Space.find(space, on: db))
            #expect(reloaded.noteCount == 2)
        }
    }

    @Test
    func `refreshSpaceCounters is no-op for empty spaceIDs`() async throws {
        try await withTestFluent(label: "lv.test.kbcompile.counters.empty") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let db = fluent.db()

            let tenantID = try await seedUser(on: fluent)
            let space = try await seedSpace(tenantID: tenantID, slug: Self.slug("e"), on: db)
            try await seedVaultFile(tenantID: tenantID, spaceID: space, index: 0, on: db)

            let service = makeService(fluent: fluent)
            try await service.refreshSpaceCounters(
                tenantID: tenantID,
                spaceIDs: [],
                at: Date(),
            )

            let reloaded = try #require(try await Space.find(space, on: db))
            #expect(reloaded.noteCount == 0)
            #expect(reloaded.lastCompiledAt == nil)
        }
    }

    // MARK: - Helpers

    private func makeService(fluent: Fluent) -> KBCompileService {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-kbcounters-\(UUID().uuidString)", isDirectory: true)
        return KBCompileService(
            vaultPaths: VaultPathService(rootPath: tmpRoot.path),
            transport: NoOpChatTransport(),
            memories: MemoryRepository(fluent: fluent),
            embeddings: DeterministicEmbeddingService(),
            defaultModel: "test-model",
            logger: Logger(label: "lv.test.kbcompile.counters"),
        )
    }

    private func seedUser(on fluent: Fluent) async throws -> UUID {
        let id = UUID()
        let slug = Self.slug("u")
        let user = User(
            id: id,
            email: "\(slug)@test.luminavault",
            username: slug,
            passwordHash: "stub-\(slug)",
        )
        try await user.save(on: fluent.db())
        return id
    }

    private func seedSpace(tenantID: UUID, slug: String, on db: any Database) async throws -> UUID {
        let space = Space(
            tenantID: tenantID,
            name: "Space \(slug)",
            slug: slug,
        )
        try await space.save(on: db)
        return try space.requireID()
    }

    private func seedVaultFile(
        tenantID: UUID,
        spaceID: UUID,
        index: Int,
        on db: any Database,
    ) async throws {
        let file = VaultFile(
            tenantID: tenantID,
            spaceID: spaceID,
            path: "\(spaceID.uuidString)/file-\(index).md",
            contentType: "text/markdown",
            sizeBytes: 16,
            sha256: String(repeating: "\(index)", count: 64).prefix(64).description,
        )
        try await file.save(on: db)
    }

    private static func slug(_ tag: String) -> String {
        "\(tag)\(UUID().uuidString.prefix(6).lowercased())"
    }
}

private actor NoOpChatTransport: HermesChatTransport {
    nonisolated func chatCompletions(payload _: Data, profileUsername _: String) async throws -> Data {
        throw NSError(domain: "noop", code: -1)
    }
}
