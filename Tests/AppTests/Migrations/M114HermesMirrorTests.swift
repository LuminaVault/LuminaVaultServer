@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import SQLKit
import Testing

/// Hermes Mirror task 3 — M114–M116 end in the expected schema: three
/// tenant-scoped tables with their unique keys and a jsonb `raw` column.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct M114HermesMirrorTests {
    private struct PgColumnRow: Codable { let column_name: String; let data_type: String }
    private struct PgIndexRow: Codable { let indexname: String; let indexdef: String }

    @Test
    func `migrations create the mirror tables with unique tenant keys`() async throws {
        try await withTestFluent(label: "lv.test.m114") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            guard let sql = fluent.db() as? any SQLDatabase else {
                Issue.record("SQL driver required")
                return
            }
            let stateColumns = try await sql.raw("""
            SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'hermes_mirror_state'
            """).all(decoding: PgColumnRow.self).map(\.column_name)
            for column in ["tenant_id", "last_sync_at", "last_status", "last_error", "skills_count", "jobs_count",
                           "vault_files_count", "vault_path", "vault_state", "vault_cursor", "sessions_cursor",
                           "sessions_imported", "compile_job_id"]
            {
                #expect(stateColumns.contains(column), "missing column: \(column)")
            }
            let stateIndexes = try await sql.raw("""
            SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'hermes_mirror_state'
            """).all(decoding: PgIndexRow.self)
            #expect(stateIndexes.contains { $0.indexdef.contains("UNIQUE") && $0.indexdef.contains("tenant_id") })

            let skillIndexes = try await sql.raw("""
            SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'hermes_mirrored_skills'
            """).all(decoding: PgIndexRow.self)
            #expect(skillIndexes.contains { $0.indexdef.contains("UNIQUE") && $0.indexdef.contains("tenant_id") && $0.indexdef.contains("name") })

            let jobColumns = try await sql.raw("""
            SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'hermes_mirrored_jobs'
            """).all(decoding: PgColumnRow.self)
            #expect(jobColumns.first { $0.column_name == "raw" }?.data_type == "jsonb")
            let jobIndexes = try await sql.raw("""
            SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'hermes_mirrored_jobs'
            """).all(decoding: PgIndexRow.self)
            #expect(jobIndexes.contains { $0.indexdef.contains("UNIQUE") && $0.indexdef.contains("hermes_job_id") })
            // M120 — the collect high-water columns.
            let jobColumnNames = jobColumns.map(\.column_name)
            #expect(jobColumnNames.contains("runs_high_water_at"))
            #expect(jobColumnNames.contains("runs_collected_at"))

            // M120 — hermes_job_runs.
            let runColumns = try await sql.raw("""
            SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'hermes_job_runs'
            """).all(decoding: PgColumnRow.self)
            for column in ["tenant_id", "hermes_job_id", "hermes_run_key", "status", "started_at", "finished_at",
                           "output", "error", "tokens", "vault_file_id", "skill_run_log_id", "collected_at"]
            {
                #expect(runColumns.contains { $0.column_name == column }, "missing column: \(column)")
            }
            #expect(runColumns.first { $0.column_name == "tokens" }?.data_type == "jsonb")
            let runIndexes = try await sql.raw("""
            SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'hermes_job_runs'
            """).all(decoding: PgIndexRow.self)
            // The run key is what makes collection idempotent, per tenant.
            #expect(runIndexes.contains { $0.indexdef.contains("UNIQUE") && $0.indexdef.contains("hermes_run_key") && $0.indexdef.contains("tenant_id") })
            // Both feed reads (per job, and the whole tenant) hit an index.
            #expect(runIndexes.contains { $0.indexdef.contains("started_at DESC") && !$0.indexdef.contains("hermes_job_id") })
            #expect(runIndexes.contains { $0.indexdef.contains("started_at DESC") && $0.indexdef.contains("hermes_job_id") })

            struct PgConstraintRow: Codable { let confdeltype: String }
            let cascade = try await sql.raw("""
            SELECT confdeltype::text AS confdeltype FROM pg_constraint
             WHERE conrelid = 'hermes_job_runs'::regclass AND contype = 'f'
               AND confrelid = 'users'::regclass
            """).all(decoding: PgConstraintRow.self)
            // Deleting a user removes their run history.
            #expect(cascade.map(\.confdeltype) == ["c"])
        }
    }

    @Test
    func `migrations are idempotent`() async throws {
        try await withTestFluent(label: "lv.test.m114.idempotent") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await fluent.migrate()
        }
    }
}
