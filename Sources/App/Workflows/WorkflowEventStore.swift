import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

actor WorkflowEventStore {
    private let fluent: Fluent
    private let logger: Logger

    init(fluent: Fluent, logger: Logger) {
        self.fluent = fluent
        self.logger = logger
    }

    @discardableResult
    func append(
        tenantID: UUID,
        runID: UUID,
        kind: WorkflowRunEventKind,
        nodeID: UUID? = nil,
        message: String? = nil,
        data: [String: String] = [:]
    ) async -> Int64? {
        guard let sql = fluent.db() as? any SQLDatabase else { return nil }
        do {
            let encoded = try JSONEncoder().encode(data)
            let json = String(decoding: encoded, as: UTF8.self)
            let row = try await sql.raw("""
            INSERT INTO workflow_run_events (tenant_id, run_id, kind, node_id, message, data)
            VALUES (\(bind: tenantID), \(bind: runID), \(bind: kind.rawValue), \(bind: nodeID),
                    \(bind: message), \(bind: json)::jsonb)
            RETURNING sequence
            """).first()
            return try row?.decode(column: "sequence", as: Int64.self)
        } catch {
            WorkflowMetrics.eventWriteFailures.increment()
            logger.error("workflow event append failed", metadata: [
                "run_id": .string(runID.uuidString),
                "kind": .string(kind.rawValue),
                "error": .string("\(error)"),
            ])
            return nil
        }
    }

    func list(tenantID: UUID, runID: UUID, after sequence: Int64 = 0, limit: Int = 250) async throws -> [WorkflowRunEventDTO] {
        guard let sql = fluent.db() as? any SQLDatabase else { return [] }
        struct EventRow: Decodable {
            let sequence: Int64
            let runID: UUID
            let kind: String
            let nodeID: UUID?
            let message: String?
            let data: [String: String]
            let createdAt: Date
        }
        let rows = try await sql.raw("""
        SELECT sequence, run_id, kind, node_id, message, data, created_at
        FROM workflow_run_events
        WHERE tenant_id = \(bind: tenantID) AND run_id = \(bind: runID) AND sequence > \(bind: sequence)
        ORDER BY sequence ASC
        LIMIT \(bind: min(max(limit, 1), 1000))
        """).all(decoding: EventRow.self)
        return rows.compactMap { row in
            guard let kind = WorkflowRunEventKind(rawValue: row.kind) else { return nil }
            return WorkflowRunEventDTO(
                id: row.sequence,
                runID: row.runID,
                kind: kind,
                nodeID: row.nodeID,
                message: row.message,
                data: row.data,
                createdAt: row.createdAt
            )
        }
    }

    func prune(before cutoff: Date) async {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        do {
            try await sql.raw("DELETE FROM workflow_run_events WHERE created_at < \(bind: cutoff)").run()
        } catch {
            logger.error("workflow event pruning failed", metadata: ["error": .string("\(error)")])
        }
    }
}
