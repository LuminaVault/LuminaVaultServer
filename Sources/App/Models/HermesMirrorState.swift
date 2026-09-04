import FluentKit
import Foundation

/// Hermes Mirror — per-tenant sync bookkeeping (one row per tenant). Counts
/// are what the last sync saw; cursors make vault and session imports
/// resumable across requests and worker ticks.
final class HermesMirrorState: Model, TenantModel, @unchecked Sendable {
    static let schema = "hermes_mirror_state"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @OptionalField(key: "last_sync_at") var lastSyncAt: Date?
    /// `never` | `ok` | `partial` | `failed` (`HermesMirrorSyncStatus`).
    @Field(key: "last_status") var lastStatus: String
    @OptionalField(key: "last_error") var lastError: String?
    @Field(key: "skills_count") var skillsCount: Int
    @Field(key: "jobs_count") var jobsCount: Int
    @Field(key: "vault_files_count") var vaultFilesCount: Int
    @OptionalField(key: "vault_path") var vaultPath: String?
    /// `absent` | `detected` | `created` | `imported` (`HermesMirrorVaultState`).
    @Field(key: "vault_state") var vaultState: String
    /// JSON `HermesVaultImportCursor` — where the last capped import stopped.
    @OptionalField(key: "vault_cursor") var vaultCursor: String?
    /// JSON `HermesSessionsImportCursor` — offset + high-water mark.
    @OptionalField(key: "sessions_cursor") var sessionsCursor: String?
    @Field(key: "sessions_imported") var sessionsImported: Int
    @OptionalField(key: "compile_job_id") var compileJobID: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(tenantID: UUID) {
        self.tenantID = tenantID
        lastStatus = "never"
        skillsCount = 0
        jobsCount = 0
        vaultFilesCount = 0
        vaultState = "absent"
        sessionsImported = 0
    }
}

/// Hermes Mirror — snapshot of one skill on the tenant's Hermes.
final class HermesMirroredSkill: Model, TenantModel, @unchecked Sendable {
    static let schema = "hermes_mirrored_skills"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "name") var name: String
    @Field(key: "description") var description: String
    @Field(key: "enabled") var enabled: Bool
    /// `builtin` | `hub` | `custom` (`HermesMirroredSkillSource`).
    @Field(key: "source") var source: String
    @OptionalField(key: "content_hash") var contentHash: String?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(tenantID: UUID, skill: HermesMirrorSkill) {
        self.tenantID = tenantID
        name = skill.name
        description = skill.description
        enabled = skill.enabled
        source = skill.source.rawValue
        contentHash = skill.contentHash
    }
}

/// Hermes Mirror — snapshot of one cron job on the tenant's Hermes. `raw`
/// keeps the source document so clients can show fields we do not model.
final class HermesMirroredJob: Model, TenantModel, @unchecked Sendable {
    static let schema = "hermes_mirrored_jobs"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "hermes_job_id") var hermesJobID: String
    @OptionalField(key: "name") var name: String?
    @OptionalField(key: "schedule") var schedule: String?
    @OptionalField(key: "prompt") var prompt: String?
    @Field(key: "paused") var paused: Bool
    @OptionalField(key: "last_run_at") var lastRunAt: Date?
    @OptionalField(key: "next_run_at") var nextRunAt: Date?
    @Field(key: "raw") var raw: JSONValue
    /// Start time of the newest *finished* run collected for this job (M120).
    /// The collector only inserts runs at or after it, so a steady state costs
    /// one listing and no output reads.
    @OptionalField(key: "runs_high_water_at") var runsHighWaterAt: Date?
    /// When the collector last completed a pass for this job.
    @OptionalField(key: "runs_collected_at") var runsCollectedAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(tenantID: UUID, job: HermesMirrorJob) {
        self.tenantID = tenantID
        hermesJobID = job.id
        apply(job)
    }

    func apply(_ job: HermesMirrorJob) {
        name = job.name
        schedule = job.schedule
        prompt = job.prompt
        paused = job.paused
        lastRunAt = job.lastRunAt
        nextRunAt = job.nextRunAt
        raw = job.raw
    }
}
