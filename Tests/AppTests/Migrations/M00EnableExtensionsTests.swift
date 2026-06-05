@testable import App
import SQLKit
import Testing

@Suite(.serialized)
struct M00EnableExtensionsTests {
    private struct ExtensionRow: Decodable {
        let extname: String
    }

    @Test
    func `prepare is safe under concurrent invocation`() async throws {
        try await withTestFluent(label: "test.m00.extensions") { fluent in
            let migration = M00_EnableExtensions()
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Stress enough concurrent callers to mimic CI fan-out (we
                // use 8 workers here as a high-contention regression check).
                for _ in 0 ..< 8 {
                    group.addTask {
                        try await migration.prepare(on: fluent.db())
                    }
                }
                try await group.waitForAll()
            }

            guard let sql = fluent.db() as? any SQLDatabase else {
                Issue.record("need SQL")
                return
            }
            let rows = try await sql.raw("""
            SELECT extname
            FROM pg_extension
            WHERE extname IN ('uuid-ossp', 'pgcrypto', 'vector', 'pg_trgm')
            """).all(decoding: ExtensionRow.self)
            let names = Set(rows.map(\.extname))
            #expect(names.contains("uuid-ossp"))
            #expect(names.contains("pgcrypto"))
            #expect(names.contains("vector"))
            #expect(names.contains("pg_trgm"))
        }
    }
}
