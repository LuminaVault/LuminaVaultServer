import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import SQLKit

/// Answers "is my brain up to date with my notes?"
///
/// Nothing in LuminaVault has ever compared the vault against what is actually
/// retrievable, so a file that failed to embed, or an edit made after the last
/// index, was invisible: the note existed, search silently could not see it,
/// and there was no signal anywhere. This is that signal.
///
/// Two kinds of drift, reported separately because they need different fixes:
///
/// - **Unindexed** — a document has no chunks at all. Backfill has not reached
///   it, or its chunking failed. Fix: run the backfill.
/// - **Stale** — a document was written to after its chunks were built
///   (`vault_files.processed_at` is newer than its newest chunk). Fix: re-index
///   that document.
///
/// Known gap: a change to the chunker's own configuration (`chunkMaxChars`,
/// overlap) also invalidates every chunk, and nothing here detects that —
/// NexusOS handles it with a stored config fingerprint. We do not persist one
/// yet, so a chunker-tuning change requires a manual full re-index.
struct VaultIndexStatusService: Sendable {
    let fluent: Fluent
    let links: VaultLinkRepository

    /// How many drifted paths to name before truncating. The counts stay exact.
    static let samplePathLimit = 20

    func status(tenantID: UUID) async throws -> VaultIndexStatus {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for index status")
        }

        let counts = try await sql.raw("""
        SELECT
            (SELECT COUNT(*) FROM vault_files WHERE tenant_id = \(bind: tenantID)) AS documents,
            (SELECT COUNT(*) FROM memory_chunks WHERE tenant_id = \(bind: tenantID)) AS chunks,
            (SELECT COUNT(*) FROM memories WHERE tenant_id = \(bind: tenantID)) AS memories,
            (SELECT MAX(created_at) FROM memory_chunks WHERE tenant_id = \(bind: tenantID)) AS last_indexed_at
        """).first(decoding: CountsRow.self)

        // Documents with no chunk rows at all.
        let unindexed = try await sql.raw("""
        SELECT v.path
        FROM vault_files v
        WHERE v.tenant_id = \(bind: tenantID)
          AND NOT EXISTS (
              SELECT 1 FROM memory_chunks c
              WHERE c.tenant_id = v.tenant_id AND c.vault_file_id = v.id
          )
        ORDER BY v.path
        """).all(decoding: PathRow.self).map(\.path)

        // Documents whose file was touched after their newest chunk was built.
        let stale = try await sql.raw("""
        SELECT v.path
        FROM vault_files v
        JOIN (
            SELECT vault_file_id, MAX(created_at) AS indexed_at
            FROM memory_chunks
            WHERE tenant_id = \(bind: tenantID) AND vault_file_id IS NOT NULL
            GROUP BY vault_file_id
        ) c ON c.vault_file_id = v.id
        WHERE v.tenant_id = \(bind: tenantID)
          AND v.processed_at IS NOT NULL
          AND v.processed_at > c.indexed_at
        ORDER BY v.path
        """).all(decoding: PathRow.self).map(\.path)

        let linkCounts = try await links.counts(tenantID: tenantID)

        var reasons: [String] = []
        if !unindexed.isEmpty {
            reasons.append("\(unindexed.count) document(s) have no chunks — run the chunk backfill")
        }
        if !stale.isEmpty {
            reasons.append("\(stale.count) document(s) changed since they were indexed")
        }
        if linkCounts.ambiguous > 0 {
            reasons.append("\(linkCounts.ambiguous) wiki link(s) match more than one document")
        }

        return VaultIndexStatus(
            documentCount: counts?.documents ?? 0,
            memoryCount: counts?.memories ?? 0,
            chunkCount: counts?.chunks ?? 0,
            resolvedLinkCount: linkCounts.resolved,
            unresolvedLinkCount: linkCounts.unresolved,
            ambiguousLinkCount: linkCounts.ambiguous,
            unindexedDocumentCount: unindexed.count,
            staleDocumentCount: stale.count,
            unindexedSample: Array(unindexed.prefix(Self.samplePathLimit)),
            staleSample: Array(stale.prefix(Self.samplePathLimit)),
            lastIndexedAt: counts?.last_indexed_at,
            stale: !reasons.isEmpty,
            staleReasons: reasons
        )
    }
}

/// Index freshness for one tenant's vault.
///
/// Server-shaped for now; promote to `LuminaVaultShared` when a client renders
/// it, per the DTO-ownership rule in `CLAUDE.md`.
struct VaultIndexStatus: Codable, Sendable {
    let documentCount: Int
    let memoryCount: Int
    let chunkCount: Int
    let resolvedLinkCount: Int
    let unresolvedLinkCount: Int
    let ambiguousLinkCount: Int
    /// Documents with no chunks — invisible to citation-bearing search.
    let unindexedDocumentCount: Int
    /// Documents edited after they were last indexed.
    let staleDocumentCount: Int
    /// First `samplePathLimit` paths of each kind; counts above are exact.
    let unindexedSample: [String]
    let staleSample: [String]
    let lastIndexedAt: Date?
    let stale: Bool
    /// Human-readable, one per distinct kind of drift. Empty when fresh.
    let staleReasons: [String]
}

private struct CountsRow: Decodable {
    let documents: Int
    let chunks: Int
    let memories: Int
    let last_indexed_at: Date?
}

private struct PathRow: Decodable {
    let path: String
}
