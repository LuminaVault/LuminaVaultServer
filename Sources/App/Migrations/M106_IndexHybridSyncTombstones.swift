import FluentKit
import SQLKit

struct M106_IndexHybridSyncTombstones: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            "CREATE INDEX memory_sync_tombstones_tenant_deleted_id_idx " +
                "ON memory_sync_tombstones (tenant_id, deleted_at, id)"
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS memory_sync_tombstones_tenant_deleted_id_idx").run()
    }
}
