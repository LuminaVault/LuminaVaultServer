import FluentKit
import Foundation
import Hummingbird
import LuminaVaultShared
import SQLKit

extension HermesMirrorService {
    static let artifactSessionCap = 200

    /// Walk recent Hermes sessions, harvest images/files/links, upsert by
    /// content hash. Caps at `HermesArtifact.retainLimit` newest per tenant.
    @discardableResult
    func collectArtifacts(tenantID: UUID) async throws -> Int {
        let transport = try await transports.transport(tenantID: tenantID)
        let page = try await transport.listSessions(offset: 0, limit: Self.artifactSessionCap)
        var inserted = 0
        for session in page.sessions {
            let messages: [HermesMirrorSessionMessage]
            do {
                messages = try await transport.sessionMessages(id: session.id)
            } catch {
                logger.debug(
                    "hermes artifacts session skipped",
                    metadata: ["tenant": "\(tenantID)", "session": "\(session.id)", "error": "\(Self.describe(error))"]
                )
                continue
            }
            let records = HermesArtifactExtractor.extract(
                sessionID: session.id,
                sessionTitle: session.title ?? "",
                sessionTimestamp: session.lastActiveAt ?? session.startedAt,
                messages: messages
            )
            for record in records {
                if try await upsertArtifact(tenantID: tenantID, record: record) {
                    inserted += 1
                }
            }
        }
        try await pruneArtifacts(tenantID: tenantID)
        return inserted
    }

    func artifacts(
        tenantID: UUID,
        kind: String?,
        query: String?,
        before: Date?,
        limit: Int
    ) async throws -> HermesArtifactListResponse {
        let bounded = max(1, min(limit, 100))
        var q = HermesArtifact.query(on: fluent.db(), tenantID: tenantID)
            .sort(\.$occurredAt, .descending)
            .sort(\.$id, .descending)
            .limit(bounded + 1)
        if let kind, let parsed = HermesArtifactKind(rawValue: kind) {
            q = q.filter(\.$kind == parsed.rawValue)
        }
        if let before {
            q = q.filter(\.$occurredAt < before)
        }
        if let query {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !needle.isEmpty {
                let escaped = needle
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                let pattern = "%\(escaped)%"
                q = q.group(.or) { or in
                    or.filter(\.$label, .custom("ILIKE"), pattern)
                    or.filter(\.$value, .custom("ILIKE"), pattern)
                    or.filter(\.$sessionTitle, .custom("ILIKE"), pattern)
                }
            }
        }
        let rows = try await q.all()
        let page = Array(rows.prefix(bounded))
        let next = rows.count > bounded ? HermesDates.iso(page.last?.occurredAt ?? Date()) : nil
        return try HermesArtifactListResponse(
            artifacts: page.map { try $0.dto() },
            nextCursor: next
        )
    }

    func artifact(tenantID: UUID, id: UUID) async throws -> HermesArtifactDTO {
        guard let row = try await HermesArtifact.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == id)
            .first()
        else {
            throw HTTPError(.notFound, message: "hermes_artifact_not_found")
        }
        return try row.dto()
    }

    private func upsertArtifact(tenantID: UUID, record: HermesArtifactExtractor.Record) async throws -> Bool {
        let existing = try await HermesArtifact.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$contentHash == record.contentHash)
            .first()
        if existing != nil {
            return false
        }
        try await HermesArtifact(tenantID: tenantID, record: record).save(on: fluent.db())
        return true
    }

    private func pruneArtifacts(tenantID: UUID) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        try await sql.raw("""
        DELETE FROM hermes_artifacts
        WHERE tenant_id = \(bind: tenantID)
          AND id NOT IN (
            SELECT id FROM hermes_artifacts
            WHERE tenant_id = \(bind: tenantID)
            ORDER BY occurred_at DESC
            LIMIT \(bind: HermesArtifact.retainLimit)
          )
        """).run()
    }
}
