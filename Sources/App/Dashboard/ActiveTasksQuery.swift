import FluentKit
import Foundation
import LuminaVaultShared
import SQLKit

/// Shared query that powers `GET /v1/tasks` and the Home Command Center
/// `activeJobs` preview. Maps real agent work into `TaskDTO` so list screens
/// and the dashboard never diverge.
///
/// Sources (v1):
/// - `workflow_runs` in `queued` / `running` / `waitingForApproval`
/// - `hermes_gateway_apply_jobs` in `running`
enum ActiveTasksQuery {
    static let defaultPreviewLimit = 5
    static let maxLimit = 100

    /// Active workflow statuses that should appear as live jobs.
    static let activeWorkflowStatuses: [String] = [
        WorkflowRunStatus.queued.rawValue,
        WorkflowRunStatus.running.rawValue,
        WorkflowRunStatus.waitingForApproval.rawValue,
    ]

    static func list(
        tenantID: UUID,
        db: any Database,
        state: TaskState? = nil,
        limit: Int = defaultPreviewLimit
    ) async throws -> [TaskDTO] {
        let capped = max(1, min(limit, maxLimit))
        var tasks: [TaskDTO] = []

        tasks += try await workflowTasks(tenantID: tenantID, db: db, limit: capped)
        tasks += try await gatewayApplyTasks(tenantID: tenantID, db: db, limit: capped)

        if let state {
            tasks = tasks.filter { $0.state == state }
        }

        // Running first, then queued; newest first within each band.
        tasks.sort { lhs, rhs in
            let lo = rank(lhs.state)
            let ro = rank(rhs.state)
            if lo != ro {
                return lo < ro
            }
            let lt = lhs.startedAt ?? .distantPast
            let rt = rhs.startedAt ?? .distantPast
            return lt > rt
        }

        if tasks.count > capped {
            tasks = Array(tasks.prefix(capped))
        }
        return tasks
    }

    static func count(tenantID: UUID, db: any Database) async throws -> Int {
        let workflows = try await activeWorkflowCount(tenantID: tenantID, db: db)
        let applies = try await activeGatewayApplyCount(tenantID: tenantID, db: db)
        return workflows + applies
    }

    // MARK: - Workflows

    private static func workflowTasks(
        tenantID: UUID,
        db: any Database,
        limit: Int
    ) async throws -> [TaskDTO] {
        guard let sql = db as? any SQLDatabase else { return [] }

        struct Row: Decodable {
            let id: UUID
            let workflowName: String
            let status: String
            let startedAt: Date?
            let createdAt: Date?
            let errorMessage: String?
        }

        let statuses = activeWorkflowStatuses
        // Bind statuses as individual values for Postgres ANY / IN.
        let rows = try await sql.raw("""
        SELECT r.id,
               COALESCE(w.name, 'Workflow') AS "workflowName",
               r.status,
               r.started_at AS "startedAt",
               r.created_at AS "createdAt",
               r.error_message AS "errorMessage"
        FROM workflow_runs r
        LEFT JOIN workflows w ON w.id = r.workflow_id
        WHERE r.tenant_id = \(bind: tenantID)
          AND r.status IN (\(bind: statuses[0]), \(bind: statuses[1]), \(bind: statuses[2]))
        ORDER BY
          CASE r.status
            WHEN 'running' THEN 0
            WHEN 'queued' THEN 1
            WHEN 'waitingForApproval' THEN 2
            ELSE 3
          END,
          COALESCE(r.started_at, r.created_at) DESC NULLS LAST
        LIMIT \(bind: limit)
        """).all(decoding: Row.self)

        let now = Date()
        return rows.map { row in
            let started = row.startedAt ?? row.createdAt
            let elapsed: Int? = started.map { Int(now.timeIntervalSince($0)) }
            return TaskDTO(
                id: row.id,
                kind: "workflow",
                label: row.workflowName,
                state: mapWorkflowStatus(row.status),
                progress: nil,
                startedAt: started,
                elapsedSeconds: elapsed,
                error: row.errorMessage
            )
        }
    }

    private static func activeWorkflowCount(tenantID: UUID, db: any Database) async throws -> Int {
        guard let sql = db as? any SQLDatabase else { return 0 }
        struct CountRow: Decodable { let count: Int }
        let statuses = activeWorkflowStatuses
        let row = try await sql.raw("""
        SELECT COUNT(*)::int AS count
        FROM workflow_runs
        WHERE tenant_id = \(bind: tenantID)
          AND status IN (\(bind: statuses[0]), \(bind: statuses[1]), \(bind: statuses[2]))
        """).first(decoding: CountRow.self)
        return row?.count ?? 0
    }

    // MARK: - Gateway apply

    private static func gatewayApplyTasks(
        tenantID: UUID,
        db: any Database,
        limit: Int
    ) async throws -> [TaskDTO] {
        let rows = try await HermesGatewayApplyJob.query(on: db)
            .filter(\.$tenantID == tenantID)
            .filter(\.$state == HermesGatewayApplyJobState.running.rawValue)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()

        let now = Date()
        return rows.compactMap { row in
            guard let id = row.id else { return nil }
            let started = row.createdAt
            let elapsed = started.map { Int(now.timeIntervalSince($0)) }
            return TaskDTO(
                id: id,
                kind: "gateway_apply",
                label: "Applying gateway config",
                state: .running,
                progress: nil,
                startedAt: started,
                elapsedSeconds: elapsed,
                error: row.errorMessage
            )
        }
    }

    private static func activeGatewayApplyCount(tenantID: UUID, db: any Database) async throws -> Int {
        try await HermesGatewayApplyJob.query(on: db)
            .filter(\.$tenantID == tenantID)
            .filter(\.$state == HermesGatewayApplyJobState.running.rawValue)
            .count()
    }

    // MARK: - Mapping

    private static func mapWorkflowStatus(_ raw: String) -> TaskState {
        switch WorkflowRunStatus(rawValue: raw) {
        case .running:
            .running
        case .queued, .waitingForApproval, .paused:
            .queued
        case .failed, .timedOut, .cancelled:
            .failed
        case .succeeded:
            .completed
        case .none:
            .queued
        }
    }

    private static func rank(_ state: TaskState) -> Int {
        switch state {
        case .running: 0
        case .queued: 1
        case .failed: 2
        case .completed: 3
        }
    }
}
