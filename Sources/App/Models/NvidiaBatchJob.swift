import FluentKit
import Foundation

/// Server-only lifecycle state for a `NvidiaBatchJob`. Not a wire DTO — the
/// client renders job status via the generic Jobs surface; this enum is the
/// persisted `state` column's domain.
enum NvidiaBatchJobState: String, CaseIterable {
    case queued
    case running
    case succeeded
    case failed
}

/// Persisted record of one NVIDIA GPU batch job. One row per submission.
/// Mirrors `HermesGatewayApplyJob` so a reconnecting client can render an
/// accurate snapshot after an app/server restart.
///
/// Foundation only: created/queried by a future `NvidiaBatchJobStore`. No
/// executor is wired yet (see `M74_CreateNvidiaBatchJobs` for why), so in
/// practice no rows exist until a dispatch channel to a GPU-backed Hermes is
/// available.
final class NvidiaBatchJob: Model, @unchecked Sendable {
    static let schema = "nvidia_batch_jobs"

    @ID(key: .id) var id: UUID?
    /// Owning tenant — jobs are per-tenant; lookups are tenant-scoped.
    @Field(key: "tenant_id") var tenantID: UUID
    /// Hermes skill ref that drives the batch, e.g. `official/mlops/nemo-curator`.
    @Field(key: "skill_ref") var skillRef: String
    /// `NvidiaBatchJobState` rawValue.
    @Field(key: "state") var state: String
    /// JSON-encoded progress steps (opaque to the server; rendered by client).
    @Field(key: "steps_json") var stepsJSON: String
    @OptionalField(key: "error_message") var errorMessage: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID = UUID(),
        tenantID: UUID,
        skillRef: String,
        state: NvidiaBatchJobState = .queued,
        stepsJSON: String = "[]",
        errorMessage: String? = nil
    ) {
        self.id = id
        self.tenantID = tenantID
        self.skillRef = skillRef
        self.state = state.rawValue
        self.stepsJSON = stepsJSON
        self.errorMessage = errorMessage
    }
}
