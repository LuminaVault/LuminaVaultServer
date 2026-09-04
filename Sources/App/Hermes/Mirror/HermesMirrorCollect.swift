import FluentKit
import Foundation
import Hummingbird
import LuminaVaultShared
import SQLKit

/// Hermes Mirror Phase 2 — "Collect": pull finished cron runs off the
/// tenant's Hermes into `hermes_job_runs`, file each non-empty output into the
/// vault as `raw/jobs/<job-slug>/<yyyy-MM-dd-HHmm>.md`, and log it as a skill
/// run so the Today feed shows it.
///
/// Idempotency rests on `hermes_job_runs (tenant_id, hermes_run_key)` being
/// unique, **not** on the high-water mark. The mark is only a read
/// optimisation: when the newest run Hermes lists is no newer than the mark,
/// the pass stops before reading a single output. Re-running a collect over an
/// overlapping window therefore inserts nothing and costs one listing.
extension HermesMirrorService {
    struct CollectLimits: Sendable {
        /// Runs pulled per job per tick. A busier job catches up next tick;
        /// `truncated` on the result says the listing filled the cap.
        var runsPerJobPerTick = 50
        /// Jobs collected per tenant per tick, so one tenant with hundreds of
        /// jobs cannot monopolise a worker slot.
        var jobsPerTick = 50
    }

    static let jobsSpaceName = "Hermes Jobs"
    static let jobProvenance = "hermes-job"
    static let collectLimits = CollectLimits()

    // MARK: - Public entry points

    /// Collect one mirrored job's new runs. `POST /v1/hermes/mirror/jobs/:id/collect`.
    func collectJobRuns(tenantID: UUID, jobID: String) async throws -> HermesJobCollectResultDTO {
        let id = try HermesJobID.validate(jobID)
        try beginExclusive(tenantID)
        defer { endExclusive(tenantID) }
        guard let job = try await mirroredJob(tenantID: tenantID, jobID: id) else {
            throw HTTPError(.notFound, message: "hermes_job_not_found")
        }
        let transport = try await transports.transport(tenantID: tenantID)
        return try await collect(tenantID: tenantID, job: job, transport: transport)
    }

    /// Collect every mirrored job for one tenant — the refresh worker's pass.
    /// A single failing job never stops the others.
    @discardableResult
    func collectAllJobRuns(tenantID: UUID) async throws -> HermesCollectSummary {
        try beginExclusive(tenantID)
        defer { endExclusive(tenantID) }
        let jobs = try await HermesMirroredJob.query(on: fluent.db(), tenantID: tenantID)
            .sort(\.$hermesJobID)
            .limit(Self.collectLimits.jobsPerTick)
            .all()
        guard !jobs.isEmpty else { return HermesCollectSummary() }
        let transport = try await transports.transport(tenantID: tenantID)
        var summary = HermesCollectSummary()
        for job in jobs {
            do {
                let result = try await collect(tenantID: tenantID, job: job, transport: transport)
                summary.jobs += 1
                summary.inserted += result.inserted
                summary.filesWritten += result.filesWritten
            } catch {
                summary.failed += 1
                logger.warning("hermes mirror collect failed", metadata: [
                    "tenant": .string(tenantID.uuidString), "job": .string(job.hermesJobID),
                    "error": "\(Self.describe(error))",
                ])
            }
        }
        return summary
    }

    /// Stored runs for one job, newest first. Reads the
    /// `(tenant_id, hermes_job_id, started_at DESC)` index — never a scan.
    func jobRuns(tenantID: UUID, jobID: String, limit: Int) async throws -> HermesJobRunsResponse {
        let id = try HermesJobID.validate(jobID)
        let bounded = max(1, min(limit, 200))
        let rows = try await HermesJobRun.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$hermesJobID == id)
            .sort(\.$startedAt, .descending)
            .limit(bounded)
            .all()
        let job = try await mirroredJob(tenantID: tenantID, jobID: id)
        return HermesJobRunsResponse(
            hermesJobID: id,
            runs: rows.map { $0.dto() },
            collectedAt: job?.runsCollectedAt
        )
    }

    struct HermesCollectSummary: Sendable, Equatable {
        var jobs = 0
        var inserted = 0
        var filesWritten = 0
        var failed = 0
    }

    // MARK: - One job

    /// Newest-first listing → insert unseen finished runs → file outputs.
    /// Runs still in flight are left for a later pass; they carry no output
    /// yet and their key would otherwise be burned on an empty row.
    private func collect(
        tenantID: UUID,
        job: HermesMirroredJob,
        transport: any HermesMirrorTransport
    ) async throws -> HermesJobCollectResultDTO {
        let jobID = job.hermesJobID
        let cap = Self.collectLimits.runsPerJobPerTick
        let listed = try await transport.jobRuns(jobID: jobID, limit: cap)
        let now = clock()
        var result = CollectCounters(fetched: listed.count, truncated: listed.count >= cap)

        // Fast path: nothing newer than what we already hold, so no output
        // reads at all. Correctness still rests on the unique run key below.
        let newest = listed.map(\.startedAt).max()
        if let highWater = job.runsHighWaterAt, let newest, newest <= highWater {
            result.skipped = listed.count
            try await markCollected(tenantID: tenantID, jobID: jobID, highWater: highWater, at: now)
            return result.dto(jobID: jobID, highWaterMark: highWater)
        }

        var highWater = job.runsHighWaterAt
        for run in listed.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard run.status != .running else {
                result.skipped += 1
                continue
            }
            if try await runExists(tenantID: tenantID, runKey: run.key) {
                result.skipped += 1
                highWater = Self.later(highWater, run.startedAt)
                continue
            }
            let wroteFile = try await store(tenantID: tenantID, job: job, run: run, transport: transport, now: now)
            result.inserted += 1
            if wroteFile {
                result.filesWritten += 1
            }
            highWater = Self.later(highWater, run.startedAt)
            // ≤ 20 reads/s against a user's Hermes.
            try await Task.sleep(for: limits.readPause)
        }

        try await markCollected(tenantID: tenantID, jobID: jobID, highWater: highWater, at: now)
        if result.inserted > 0 {
            logger.info("hermes mirror collect", metadata: [
                "tenant": .string(tenantID.uuidString), "job": .string(jobID),
                "inserted": "\(result.inserted)", "files": "\(result.filesWritten)",
            ])
        }
        return result.dto(jobID: jobID, highWaterMark: highWater)
    }

    /// Reads the run's output, files it, and writes the run row. Returns
    /// whether a vault file was written.
    ///
    /// The insert is last and its unique `(tenant_id, hermes_run_key)` index
    /// is the idempotency guard: two collectors racing the same run leave one
    /// row, and the loser's vault write is a content-identical no-op because
    /// `VaultIngestService` dedupes on path + sha256.
    private func store(
        tenantID: UUID,
        job: HermesMirroredJob,
        run: HermesMirrorJobRun,
        transport: any HermesMirrorTransport,
        now: Date
    ) async throws -> Bool {
        var markdown: String?
        if run.status == .ok {
            markdown = try? await transport.jobRunOutput(jobID: job.hermesJobID, runKey: run.key)
        }
        let trimmed = markdown?.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = (trimmed?.isEmpty == false) ? HermesJobRun.truncate(markdown ?? "") : nil

        var vaultFileID: UUID?
        var spaceID: UUID?
        if let output {
            let ingested = try await ingest.ingestBatch(
                tenantID: tenantID,
                spaceName: Self.jobsSpaceName,
                files: [.init(path: Self.jobOutputVaultPath(job: job, run: run), content: output)],
                provenance: Self.jobProvenance
            )
            vaultFileID = ingested.vaultFileIDs.first
            spaceID = ingested.spaceID
        }

        let logID = try await recordSkillRun(
            tenantID: tenantID, job: job, run: run, output: output, spaceID: spaceID
        )

        let row = HermesJobRun(tenantID: tenantID, jobID: job.hermesJobID, run: run, collectedAt: now)
        row.output = output
        row.vaultFileID = vaultFileID
        row.skillRunLogID = logID
        try await row.save(on: fluent.db())
        return vaultFileID != nil
    }

    /// `raw/jobs/<job-slug>/<yyyy-MM-dd-HHmm>.md`. The slug comes from the
    /// job's name when it has one so the folder is readable, and falls back to
    /// the Hermes id.
    static func jobOutputVaultPath(job: HermesMirroredJob, run: HermesMirrorJobRun) -> String {
        let name = job.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = ImportService.slugify(name?.isEmpty == false ? (name ?? "") : job.hermesJobID)
        return "raw/jobs/\(slug.isEmpty ? job.hermesJobID : slug)/\(stamp(run.startedAt)).md"
    }

    /// `yyyy-MM-dd-HHmm`, UTC — the same instant Hermes named the run after.
    static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d-%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0
        )
    }

    // MARK: - Persistence helpers

    /// Writes only the two collect columns. Deliberately not `job.save()`:
    /// `hermes_mirrored_jobs.raw` is a `JSONValue` on a `jsonb` column, and
    /// re-saving a row loaded from Postgres would rewrite that column from the
    /// text PostgresNIO handed back rather than the object it holds. Only the
    /// jobs sync, which reassigns `raw` from a live listing, may save the row.
    private func markCollected(tenantID: UUID, jobID: String, highWater: Date?, at now: Date) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        try await sql.raw("""
        UPDATE hermes_mirrored_jobs
           SET runs_high_water_at = \(bind: highWater), runs_collected_at = \(bind: now)
         WHERE tenant_id = \(bind: tenantID) AND hermes_job_id = \(bind: jobID)
        """).run()
    }

    private func mirroredJob(tenantID: UUID, jobID: String) async throws -> HermesMirroredJob? {
        // Fluent query builder, not a collection.
        // swiftlint:disable:next first_where
        try await HermesMirroredJob.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$hermesJobID == jobID)
            .first()
    }

    private func runExists(tenantID: UUID, runKey: String) async throws -> Bool {
        try await HermesJobRun.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$hermesRunKey == runKey)
            .count() > 0
    }

    /// One `skill_run_log` row per collected run so the run shows up wherever
    /// local skill runs do (skill detail, dashboard counts, usage reports).
    /// `skill_run_log` is a raw-SQL table with no Fluent model.
    private func recordSkillRun(
        tenantID: UUID,
        job: HermesMirroredJob,
        run: HermesMirrorJobRun,
        output: String?,
        spaceID: UUID?
    ) async throws -> UUID? {
        guard let sql = fluent.db() as? any SQLDatabase else { return nil }
        let logID = UUID()
        let name = job.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let skillName = (name?.isEmpty == false ? name : nil) ?? job.hermesJobID
        let status = run.status == .error ? SkillRunStatus.error.rawValue : SkillRunStatus.success.rawValue
        try await sql.raw("""
        INSERT INTO skill_run_log
            (id, tenant_id, source, name, started_at, ended_at, status, error, model_used, mtok_in, mtok_out, markdown, space_id)
        VALUES
            (\(bind: logID), \(bind: tenantID), \(bind: SkillSource.hermes.rawValue), \(bind: skillName),
             \(bind: run.startedAt), \(bind: run.finishedAt ?? run.startedAt), \(bind: status), \(bind: run.error),
             \(bind: nil as String?), \(bind: run.tokensIn ?? 0), \(bind: run.tokensOut ?? 0),
             \(bind: output), \(bind: spaceID))
        """).run()
        return logID
    }

    static func later(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }

    private struct CollectCounters {
        let fetched: Int
        let truncated: Bool
        var inserted = 0
        var skipped = 0
        var filesWritten = 0

        func dto(jobID: String, highWaterMark: Date?) -> HermesJobCollectResultDTO {
            HermesJobCollectResultDTO(
                hermesJobID: jobID,
                fetched: fetched,
                inserted: inserted,
                skipped: skipped,
                filesWritten: filesWritten,
                truncated: truncated,
                highWaterMark: highWaterMark
            )
        }
    }
}
