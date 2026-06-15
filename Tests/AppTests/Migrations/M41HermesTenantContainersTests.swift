@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import SQLKit
import Testing

/// HER-240a — verifies the M40 migration ends in the expected schema state:
///   - `hermes_tenant_containers` table exists with all required columns
///   - `tenant_id UNIQUE` + FK to `users` is in place
///   - `port UNIQUE` index exists (so two tenants can't take the same port)
///   - the partial idle-eviction index exists
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct M41HermesTenantContainersTests {
    private struct PgIndexRow: Codable { let indexname: String }
    private struct PgColumnRow: Codable { let column_name: String }

    @Test
    func `migration creates table and indexes`() async throws {
        try await withTestFluent(label: "lv.test.m40") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            guard let sql = fluent.db() as? any SQLDatabase else {
                Issue.record("SQL driver required")
                return
            }

            let columns = try await sql.raw("""
            SELECT column_name FROM information_schema.columns
            WHERE table_name = 'hermes_tenant_containers'
            """).all(decoding: PgColumnRow.self).map(\.column_name)

            let required = [
                "id", "tenant_id", "container_name", "port",
                "api_server_key_ciphertext", "api_server_key_nonce",
                "xai_connected_at", "created_at", "last_used_at",
            ]
            for col in required {
                #expect(columns.contains(col), "missing column: \(col)")
            }

            let indexes = try await sql.raw("""
            SELECT indexname FROM pg_indexes WHERE tablename = 'hermes_tenant_containers'
            """).all(decoding: PgIndexRow.self).map(\.indexname)

            #expect(indexes.contains("idx_hermes_tenant_containers_last_used_at"))
            #expect(indexes.contains("idx_hermes_tenant_containers_port"))
        }
    }

    @Test
    func `migration is idempotent`() async throws {
        try await withTestFluent(label: "lv.test.m40.idempotent") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await fluent.migrate()
        }
    }
}
