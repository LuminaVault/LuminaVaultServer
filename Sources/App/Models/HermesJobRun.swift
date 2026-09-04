import FluentKit
import Foundation
import LuminaVaultShared

/// Hermes Mirror Phase 2 — one collected run of a mirrored Hermes cron job
/// (M120). `hermesRunKey` is Hermes' identity for the run and is unique per
/// tenant, which is what makes the collect pass idempotent: re-reading an
/// overlapping window inserts nothing.
///
/// `output` is capped at `HermesJobRun.maxOutputBytes` — the full markdown
/// also lands in the vault as `raw/jobs/<job>/<stamp>.md`, so this column is
/// the feed preview, not the archive.
final class HermesJobRun: Model, TenantModel, @unchecked Sendable {
    static let schema = "hermes_job_runs"

    /// 256 KiB. Longer outputs are truncated for the column and the feed;
    /// the vault file carries the same truncated body so the two agree.
    static let maxOutputBytes = 256 * 1024

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "hermes_job_id") var hermesJobID: String
    @Field(key: "hermes_run_key") var hermesRunKey: String
    /// `running` | `ok` | `error` (`HermesJobRunStatus`).
    @Field(key: "status") var status: String
    @Field(key: "started_at") var startedAt: Date
    @OptionalField(key: "finished_at") var finishedAt: Date?
    @OptionalField(key: "output") var output: String?
    @OptionalField(key: "error") var error: String?
    /// `{"input": Int?, "output": Int?}` when Hermes reported usage.
    ///
    /// Typed rather than `JSONValue`: PostgresNIO decodes a `jsonb` column
    /// into a single-value-container type as the raw JSON *text*, so a
    /// `JSONValue` field would read back as `.string("{...}")`. A keyed
    /// `Codable` struct takes the JSON path and round-trips correctly.
    @OptionalField(key: "tokens") var tokens: HermesJobRunTokensDTO?
    @OptionalField(key: "vault_file_id") var vaultFileID: UUID?
    /// `skill_run_log.id` — that table is raw SQL, so this is an unconstrained
    /// reference kept in step by the collector.
    @OptionalField(key: "skill_run_log_id") var skillRunLogID: UUID?
    @Field(key: "collected_at") var collectedAt: Date

    init() {}

    init(tenantID: UUID, jobID: String, run: HermesMirrorJobRun, collectedAt: Date) {
        self.tenantID = tenantID
        hermesJobID = jobID
        hermesRunKey = run.key
        status = run.status.rawValue
        startedAt = run.startedAt
        finishedAt = run.finishedAt
        error = run.error
        tokens = Self.tokens(input: run.tokensIn, output: run.tokensOut)
        self.collectedAt = collectedAt
    }

    static func tokens(input: Int?, output: Int?) -> HermesJobRunTokensDTO? {
        guard input != nil || output != nil else { return nil }
        return HermesJobRunTokensDTO(input: input, output: output)
    }

    static let truncationMarker = "\n\n_[truncated by LuminaVault at 256 KiB]_\n"

    /// Cuts to `maxOutputBytes` on a grapheme boundary — the cap bounds
    /// storage, so it must never split a character and produce mojibake — and
    /// marks the cut so a reader knows the body is partial.
    static func truncate(_ markdown: String) -> String {
        guard markdown.utf8.count > maxOutputBytes else { return markdown }
        var end = markdown.startIndex
        var index = markdown.startIndex
        var used = 0
        while index < markdown.endIndex {
            let next = markdown.index(after: index)
            let size = markdown.utf8.distance(from: index, to: next)
            if used + size > maxOutputBytes {
                break
            }
            used += size
            end = next
            index = next
        }
        return String(markdown[..<end]) + truncationMarker
    }

    func dto() -> HermesJobRunDTO {
        HermesJobRunDTO(
            id: id ?? UUID(),
            hermesJobID: hermesJobID,
            runKey: hermesRunKey,
            status: HermesJobRunStatus(rawValue: status) ?? .ok,
            startedAt: startedAt,
            finishedAt: finishedAt,
            output: output,
            error: error,
            tokens: tokens,
            vaultFilePath: nil,
            skillRunLogID: skillRunLogID,
            collectedAt: collectedAt
        )
    }
}
