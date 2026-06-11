import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import SQLKit

/// HER-290 — durable `(tenant_id, content_hash)` reject-list. Used by:
/// * `MemoryCompileService` at compile-start to skip already-rejected content
///   (see `loadRejectedHashes`).
/// * `MemoryController.patch` when a user rejects a memory.
struct KBCompileRejectListRepository {
    let fluent: Fluent

    /// Idempotent insert. If the `(tenant_id, content_hash)` pair already
    /// exists, the unique constraint suppresses the duplicate silently.
    func record(
        tenantID: UUID,
        contentHash: String,
        vaultFileID: UUID?
    ) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for reject-list insert")
        }
        try await sql.raw("""
        INSERT INTO kb_compile_reject_list (id, tenant_id, content_hash, vault_file_id, rejected_at)
        VALUES (\(bind: UUID()), \(bind: tenantID), \(bind: contentHash), \(bind: vaultFileID), NOW())
        ON CONFLICT (tenant_id, content_hash) DO NOTHING
        """).run()
    }
}
