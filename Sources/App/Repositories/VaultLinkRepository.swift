import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import SQLKit

/// One outgoing link, as returned to callers.
struct OutgoingLinkRow: Sendable, Codable {
    let sourceLine: Int
    let rawTarget: String
    let targetSlug: String
    let targetHeading: String?
    let label: String?
    let resolutionState: String
    /// Path of the document this points at; nil unless resolved.
    let targetPath: String?
}

/// One incoming link — a backlink.
struct IncomingLinkRow: Sendable, Codable {
    let sourcePath: String?
    let sourceLine: Int
    let rawTarget: String
    let targetSlug: String
    let resolutionState: String
}

/// Link-graph counts for status and lint.
struct VaultLinkCounts: Sendable, Codable {
    let resolved: Int
    let unresolved: Int
    let ambiguous: Int
}

/// Persistence for the `[[wikilink]]` graph.
///
/// Raw SQL throughout, so — as with `MemoryChunkRepository` — **every query
/// must bind `tenant_id` explicitly**; there is no inherited `TenantModel` row
/// filter to fall back on.
struct VaultLinkRepository {
    let fluent: Fluent

    // MARK: - Write

    /// Replace every link belonging to one source document.
    ///
    /// Delete-then-insert in a transaction: a document that lost a link must
    /// not keep a stale edge, and a half-rewritten document must never be
    /// visible to the graph.
    ///
    /// Links are resolved against the vault as it exists *now*. A link to a
    /// note that does not exist yet is stored `unresolved` and upgraded later
    /// by `reresolve(tenantID:)` — that is the correct behavior for a vault
    /// where people link forward to notes they intend to write.
    func replaceLinks(
        tenantID: UUID,
        sourceVaultFileID: UUID,
        sourcePath: String?,
        links: [ParsedWikilink]
    ) async throws {
        let candidates = try await targets(tenantID: tenantID)
        let resolved = WikilinkResolver.resolve(links: links, candidates: candidates)

        try await fluent.db().transaction { db in
            guard let tx = db as? any SQLDatabase else {
                throw HTTPError(.internalServerError, message: "SQL driver required for link write")
            }
            try await tx.raw("""
            DELETE FROM vault_links
            WHERE tenant_id = \(bind: tenantID) AND source_vault_file_id = \(bind: sourceVaultFileID)
            """).run()

            for item in resolved {
                try await tx.raw("""
                INSERT INTO vault_links (
                    tenant_id, source_vault_file_id, source_path, source_line,
                    raw_target, target_slug, target_heading, label,
                    target_vault_file_id, resolved, resolution_state, created_at
                ) VALUES (
                    \(bind: tenantID), \(bind: sourceVaultFileID), \(bind: sourcePath),
                    \(bind: item.link.line), \(bind: item.link.rawTarget), \(bind: item.link.targetSlug),
                    \(bind: item.link.targetHeading), \(bind: item.link.label),
                    \(bind: item.targetVaultFileID), \(bind: item.state == .resolved),
                    \(bind: item.state.rawValue), NOW()
                )
                """).run()
            }
        }
    }

    /// Re-resolve every link in the tenant against the current document set.
    ///
    /// Needed because resolution is a whole-vault property: creating one note
    /// can resolve dozens of previously dangling links, and deleting one can
    /// break them. Cheap enough to run after an import batch — it is a single
    /// read of the candidate set plus one UPDATE per changed row.
    ///
    /// - Returns: how many rows changed state.
    @discardableResult
    func reresolve(tenantID: UUID) async throws -> Int {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for link resolution")
        }
        let candidates = try await targets(tenantID: tenantID)
        let rows = try await sql.raw("""
        SELECT link_id, source_line, raw_target, target_slug, target_heading, label,
               target_vault_file_id, resolution_state
        FROM vault_links
        WHERE tenant_id = \(bind: tenantID)
        """).all(decoding: StoredLinkRow.self)
        guard !rows.isEmpty else { return 0 }

        let parsed = rows.map {
            ParsedWikilink(
                line: $0.source_line,
                rawTarget: $0.raw_target,
                targetSlug: $0.target_slug,
                targetHeading: $0.target_heading,
                label: $0.label
            )
        }
        let resolved = WikilinkResolver.resolve(links: parsed, candidates: candidates)

        var changed = 0
        for (row, item) in zip(rows, resolved) {
            guard row.resolution_state != item.state.rawValue
                || row.target_vault_file_id != item.targetVaultFileID
            else { continue }
            try await sql.raw("""
            UPDATE vault_links
            SET target_vault_file_id = \(bind: item.targetVaultFileID),
                resolved = \(bind: item.state == .resolved),
                resolution_state = \(bind: item.state.rawValue)
            WHERE tenant_id = \(bind: tenantID) AND link_id = \(bind: row.link_id)
            """).run()
            changed += 1
        }
        return changed
    }

    // MARK: - Read

    /// Outgoing links for one document, in source order.
    func outgoing(tenantID: UUID, vaultFileID: UUID) async throws -> [OutgoingLinkRow] {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for link read")
        }
        return try await sql.raw("""
        SELECT l.source_line, l.raw_target, l.target_slug, l.target_heading, l.label,
               l.resolution_state, t.path AS target_path
        FROM vault_links l
        LEFT JOIN vault_files t
            ON t.id = l.target_vault_file_id AND t.tenant_id = l.tenant_id
        WHERE l.tenant_id = \(bind: tenantID) AND l.source_vault_file_id = \(bind: vaultFileID)
        ORDER BY l.source_line, l.link_id
        """).all(decoding: OutgoingJoinRow.self).map {
            OutgoingLinkRow(
                sourceLine: $0.source_line,
                rawTarget: $0.raw_target,
                targetSlug: $0.target_slug,
                targetHeading: $0.target_heading,
                label: $0.label,
                resolutionState: $0.resolution_state,
                targetPath: $0.target_path
            )
        }
    }

    /// Backlinks: every link that resolves to this document.
    func incoming(tenantID: UUID, vaultFileID: UUID) async throws -> [IncomingLinkRow] {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for link read")
        }
        return try await sql.raw("""
        SELECT l.source_path, l.source_line, l.raw_target, l.target_slug, l.resolution_state
        FROM vault_links l
        WHERE l.tenant_id = \(bind: tenantID) AND l.target_vault_file_id = \(bind: vaultFileID)
        ORDER BY l.source_path NULLS LAST, l.source_line, l.link_id
        """).all(decoding: IncomingJoinRow.self).map {
            IncomingLinkRow(
                sourcePath: $0.source_path,
                sourceLine: $0.source_line,
                rawTarget: $0.raw_target,
                targetSlug: $0.target_slug,
                resolutionState: $0.resolution_state
            )
        }
    }

    /// Counts by resolution state — feeds vault status and lint.
    func counts(tenantID: UUID) async throws -> VaultLinkCounts {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for link counts")
        }
        let rows = try await sql.raw("""
        SELECT resolution_state, COUNT(*) AS total
        FROM vault_links
        WHERE tenant_id = \(bind: tenantID)
        GROUP BY resolution_state
        """).all(decoding: StateCountRow.self)
        let byState = Dictionary(rows.map { ($0.resolution_state, $0.total) }, uniquingKeysWith: { first, _ in first })
        return VaultLinkCounts(
            resolved: byState[WikilinkResolutionState.resolved.rawValue] ?? 0,
            unresolved: byState[WikilinkResolutionState.unresolved.rawValue] ?? 0,
            ambiguous: byState[WikilinkResolutionState.ambiguous.rawValue] ?? 0
        )
    }

    /// Documents nothing links to. Lint's `orphans` check.
    func orphanPaths(tenantID: UUID, limit: Int = 200) async throws -> [String] {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for orphan scan")
        }
        return try await sql.raw("""
        SELECT v.path
        FROM vault_files v
        WHERE v.tenant_id = \(bind: tenantID)
          AND NOT EXISTS (
              SELECT 1 FROM vault_links l
              WHERE l.tenant_id = v.tenant_id AND l.target_vault_file_id = v.id
          )
        ORDER BY v.path
        LIMIT \(bind: max(1, limit))
        """).all(decoding: PathRow.self).map(\.path)
    }

    /// Candidate link targets: every indexed file in the tenant.
    private func targets(tenantID: UUID) async throws -> [WikilinkTarget] {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for link resolution")
        }
        return try await sql.raw("""
        SELECT id, path FROM vault_files WHERE tenant_id = \(bind: tenantID)
        """).all(decoding: TargetRow.self).map {
            WikilinkTarget(vaultFileID: $0.id, path: $0.path)
        }
    }
}

private struct TargetRow: Decodable {
    let id: UUID
    let path: String
}

private struct StoredLinkRow: Decodable {
    let link_id: Int64
    let source_line: Int
    let raw_target: String
    let target_slug: String
    let target_heading: String?
    let label: String?
    let target_vault_file_id: UUID?
    let resolution_state: String
}

private struct OutgoingJoinRow: Decodable {
    let source_line: Int
    let raw_target: String
    let target_slug: String
    let target_heading: String?
    let label: String?
    let resolution_state: String
    let target_path: String?
}

private struct IncomingJoinRow: Decodable {
    let source_path: String?
    let source_line: Int
    let raw_target: String
    let target_slug: String
    let resolution_state: String
}

private struct StateCountRow: Decodable {
    let resolution_state: String
    let total: Int
}

private struct PathRow: Decodable {
    let path: String
}
