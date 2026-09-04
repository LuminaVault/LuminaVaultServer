import FluentKit
import Foundation
import Hummingbird
import LuminaVaultShared

/// Hermes Mirror Phase 2 — write access to the tenant's cron jobs: create,
/// partial update, pause/resume, trigger and delete.
///
/// Every mutation is "do it on Hermes, then mirror what Hermes answered".
/// Hermes owns the schedule (it is the thing that fires), so LuminaVault
/// never writes a job row it has not seen echoed back; a mutation that fails
/// upstream therefore leaves the mirror exactly as it was rather than
/// promising a change the user's Hermes never made.
///
/// The mirrored row is refreshed in the same call so `GET /jobs` reflects the
/// change immediately instead of waiting for the next sync — with the one
/// caveat that `apply(_:)` reassigns `raw` from the response, which is what
/// makes saving the row safe (see `markCollected` for why re-saving a row
/// loaded from Postgres would otherwise corrupt that `jsonb` column).
extension HermesMirrorService {
    /// Runs returned by `GET /jobs/{id}/runs`. The dashboard caps its own
    /// listing at 100; this reads stored rows, so the ceiling is only about
    /// response size.
    static let maxJobRunsLimit = 200
    static let defaultJobRunsLimit = 50

    // MARK: - Create

    /// `POST /v1/hermes/mirror/jobs` — the full Hermes `CronJobCreate` body.
    func createJob(tenantID: UUID, request: HermesJobCreateRequest) async throws -> HermesMirroredJobDTO {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule = request.schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw HTTPError(.badRequest, message: "hermes_job_name_required")
        }
        guard !schedule.isEmpty else {
            throw HTTPError(.badRequest, message: "hermes_job_schedule_required")
        }
        let transport = try await transports.transport(tenantID: tenantID)
        let created = try await transport.createJob(HermesMirrorJobSpec(request))
        let row = try await mirroredJob(tenantID: tenantID, jobID: created.id)
            ?? HermesMirroredJob(tenantID: tenantID, job: created)
        row.apply(created)
        try await row.save(on: fluent.db())
        return Self.jobDTO(row)
    }

    // MARK: - Mutate

    /// Partial update. An empty body is refused rather than sent on: Hermes
    /// treats `{"updates": {}}` as a no-op write and answers 200, which would
    /// read to a client as "your change was applied".
    func updateJob(tenantID: UUID, jobID: String, request: HermesJobUpdateRequest) async throws -> HermesMirroredJobDTO {
        guard !request.isEmpty else {
            throw HTTPError(.badRequest, message: "hermes_job_update_empty")
        }
        return try await mutateJob(tenantID: tenantID, jobID: jobID) { transport, id in
            try await transport.updateJob(id: id, updates: HermesMirrorJobUpdate(request))
        }
    }

    func pauseJob(tenantID: UUID, jobID: String) async throws -> HermesMirroredJobDTO {
        try await mutateJob(tenantID: tenantID, jobID: jobID) { transport, id in
            try await transport.pauseJob(id: id)
        }
    }

    func resumeJob(tenantID: UUID, jobID: String) async throws -> HermesMirroredJobDTO {
        try await mutateJob(tenantID: tenantID, jobID: jobID) { transport, id in
            try await transport.resumeJob(id: id)
        }
    }

    /// Fires the job on Hermes' next scheduler tick. The run itself is
    /// collected the usual way — this does not wait for output.
    func triggerJob(tenantID: UUID, jobID: String) async throws -> HermesMirroredJobDTO {
        try await mutateJob(tenantID: tenantID, jobID: jobID) { transport, id in
            try await transport.triggerJob(id: id)
        }
    }

    /// Deletes the job on Hermes and drops the mirrored row. Collected runs
    /// in `hermes_job_runs` are deliberately kept: they are history the user
    /// already has in the vault and on the Today feed, and deleting a
    /// schedule is not a request to forget what it produced.
    func deleteJob(tenantID: UUID, jobID: String) async throws {
        let id = try HermesJobID.validate(jobID)
        guard let row = try await mirroredJob(tenantID: tenantID, jobID: id) else {
            throw HTTPError(.notFound, message: "hermes_job_not_found")
        }
        let transport = try await transports.transport(tenantID: tenantID)
        try await transport.deleteJob(id: id)
        try await row.delete(on: fluent.db())
    }

    /// Shared shape: validate the id, refuse an id this tenant does not
    /// mirror, mutate upstream, then mirror the answer.
    private func mutateJob(
        tenantID: UUID,
        jobID: String,
        _ mutate: (any HermesMirrorTransport, String) async throws -> HermesMirrorJob
    ) async throws -> HermesMirroredJobDTO {
        let id = try HermesJobID.validate(jobID)
        guard let row = try await mirroredJob(tenantID: tenantID, jobID: id) else {
            throw HTTPError(.notFound, message: "hermes_job_not_found")
        }
        let transport = try await transports.transport(tenantID: tenantID)
        let updated = try await mutate(transport, id)
        row.apply(updated)
        try await row.save(on: fluent.db())
        return Self.jobDTO(row)
    }
}
