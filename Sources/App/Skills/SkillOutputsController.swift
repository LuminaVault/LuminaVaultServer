import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

extension SkillOutputListResponse: @retroactive ResponseEncodable {}

/// `GET /v1/skills/outputs` — the Today-tab feed (HER-177).
///
/// One page, newest first, unioning two sources:
///
/// - **local skill runs** — `skill_run_log` rows that produced markdown,
///   excluding `source = 'hermes'`; those rows exist so Hermes runs show up on
///   the skill surfaces and in usage reports, but they would duplicate the
///   arm below, which carries the vault path as well.
/// - **Hermes job runs** — `hermes_job_runs` (Phase 2 "Collect"), joined to
///   the mirrored job for its name and to `vault_files` for the path of the
///   file the output was filed as.
///
/// Both arms filter and sort on `started_at`, which each table indexes by
/// `(tenant_id, started_at DESC)`, and each is limited before the union, so
/// the query sorts at most `2 × limit` rows and never scans a table.
/// `createdAt` on the wire is that same `started_at`, so the client's
/// "newest I have seen" value round-trips exactly through `since`.
struct SkillOutputsController {
    let fluent: Fluent
    let logger: Logger

    private static let maxLimit = 100
    private static let defaultLimit = 50
    /// Days of history considered when counting the streak.
    private static let streakWindowDays = 60
    /// A local run is only "active" while it is plausibly still going.
    private static let activeRunWindowSeconds = 3600

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/outputs", use: list)
    }

    @Sendable
    func list(_ req: Request, ctx: AppRequestContext) async throws -> SkillOutputListResponse {
        let tenantID = try ctx.requireTenantID()
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "skill outputs require SQL driver")
        }
        let limit = Self.limit(req)
        let since = Self.date(req, "since")
        let before = Self.date(req, "before")

        let rows = try await Self.page(on: sql, tenantID: tenantID, since: since, before: before, limit: limit)
        let outputs = rows.map(Self.output)
        return try await SkillOutputListResponse(
            outputs: outputs,
            streakDays: Self.streak(on: sql, tenantID: tenantID),
            activeRun: Self.hasActiveRun(on: sql, tenantID: tenantID),
            // Only a full page can have more behind it; the value is the
            // exclusive upper bound for the next call's `before`.
            nextCursor: outputs.count == limit ? outputs.last.map { HermesDates.iso($0.createdAt) } : nil
        )
    }

    // MARK: - Query

    struct FeedRow: Decodable {
        let id: UUID
        let name: String
        let source: String
        let started_at: Date
        let status: String
        let error: String?
        let markdown: String?
        let vault_path: String?
    }

    static func page(
        on sql: any SQLDatabase,
        tenantID: UUID,
        since: Date?,
        before: Date?,
        limit: Int
    ) async throws -> [FeedRow] {
        // `since`/`before` are exclusive bounds; a nil bound is neutralised
        // with a `\(bind:)`-guarded OR so the statement stays a single
        // prepared shape instead of being concatenated per call.
        try await sql.raw("""
        SELECT * FROM (
            (SELECT id, name, source, started_at, status, error, markdown, NULL::text AS vault_path
               FROM skill_run_log
              WHERE tenant_id = \(bind: tenantID)
                AND source <> \(bind: SkillSource.hermes.rawValue)
                AND markdown IS NOT NULL AND markdown <> ''
                AND (\(bind: since)::timestamptz IS NULL OR started_at > \(bind: since)::timestamptz)
                AND (\(bind: before)::timestamptz IS NULL OR started_at < \(bind: before)::timestamptz)
              ORDER BY started_at DESC
              LIMIT \(bind: limit))
            UNION ALL
            (SELECT r.id, COALESCE(NULLIF(j.name, ''), r.hermes_job_id) AS name,
                    \(bind: SkillSource.hermes.rawValue) AS source, r.started_at, r.status, r.error,
                    r.output AS markdown, f.path AS vault_path
               FROM hermes_job_runs r
               LEFT JOIN hermes_mirrored_jobs j
                      ON j.tenant_id = r.tenant_id AND j.hermes_job_id = r.hermes_job_id
               LEFT JOIN vault_files f ON f.id = r.vault_file_id
              WHERE r.tenant_id = \(bind: tenantID)
                AND r.status <> \(bind: HermesJobRunStatus.running.rawValue)
                AND (r.output IS NOT NULL OR r.error IS NOT NULL)
                AND (\(bind: since)::timestamptz IS NULL OR r.started_at > \(bind: since)::timestamptz)
                AND (\(bind: before)::timestamptz IS NULL OR r.started_at < \(bind: before)::timestamptz)
              ORDER BY r.started_at DESC
              LIMIT \(bind: limit))
        ) feed
        ORDER BY started_at DESC
        LIMIT \(bind: limit)
        """).all(decoding: FeedRow.self)
    }

    /// Consecutive days (UTC) with at least one output, counted back from
    /// today; a gap of one day still counts if yesterday produced something,
    /// so a streak is not lost before the day is over.
    static func streak(on sql: any SQLDatabase, tenantID: UUID) async throws -> Int {
        struct DayRow: Decodable { let day: Date }
        let days = try await sql.raw("""
        SELECT DISTINCT date_trunc('day', started_at AT TIME ZONE 'UTC') AS day FROM (
            SELECT started_at FROM skill_run_log
             WHERE tenant_id = \(bind: tenantID) AND source <> \(bind: SkillSource.hermes.rawValue)
               AND markdown IS NOT NULL AND markdown <> ''
               AND started_at > NOW() - (\(bind: streakWindowDays) * INTERVAL '1 day')
            UNION ALL
            SELECT started_at FROM hermes_job_runs
             WHERE tenant_id = \(bind: tenantID) AND status <> \(bind: HermesJobRunStatus.running.rawValue)
               AND started_at > NOW() - (\(bind: streakWindowDays) * INTERVAL '1 day')
        ) all_runs
        ORDER BY day DESC
        """).all(decoding: DayRow.self)
        return streakLength(days: days.map(\.day), today: Date())
    }

    static func streakLength(days: [Date], today: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let present = Set(days.map { calendar.startOfDay(for: $0) })
        guard !present.isEmpty else { return 0 }
        var cursor = calendar.startOfDay(for: today)
        // Today may not have produced anything yet; start from yesterday then.
        if !present.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor), present.contains(yesterday) else {
                return 0
            }
            cursor = yesterday
        }
        var count = 0
        while present.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    /// True while a local skill run is pending/running (bounded to the last
    /// hour so a crashed run does not pin the mascot on "thinking"), or a
    /// Hermes job run is still in flight.
    static func hasActiveRun(on sql: any SQLDatabase, tenantID: UUID) async throws -> Bool {
        struct FlagRow: Decodable { let active: Bool }
        let row = try await sql.raw("""
        SELECT (
            EXISTS (SELECT 1 FROM skill_run_log
                     WHERE tenant_id = \(bind: tenantID)
                       AND status IN (\(bind: SkillRunStatus.pending.rawValue), \(bind: SkillRunStatus.running.rawValue))
                       AND started_at > NOW() - (\(bind: activeRunWindowSeconds) * INTERVAL '1 second'))
            OR
            EXISTS (SELECT 1 FROM hermes_job_runs
                     WHERE tenant_id = \(bind: tenantID)
                       AND status = \(bind: HermesJobRunStatus.running.rawValue))
        ) AS active
        """).first(decoding: FlagRow.self)
        return row?.active ?? false
    }

    // MARK: - Shaping

    static func output(_ row: FeedRow) -> SkillOutputDTO {
        let failed = row.status == SkillRunStatus.error.rawValue || row.status == HermesJobRunStatus.error.rawValue
        let body = (row.markdown?.isEmpty == false ? row.markdown : nil)
            ?? row.error
            ?? ""
        return SkillOutputDTO(
            id: row.id,
            skillName: row.name,
            source: SkillSource(rawValue: row.source) ?? .builtin,
            kind: kind(for: row.name),
            headline: failed && row.markdown?.isEmpty != false ? "\(row.name) failed" : headline(body: body, fallback: row.name),
            body: body,
            createdAt: row.started_at,
            memoryID: nil,
            memoID: nil,
            vaultFilePath: row.vault_path
        )
    }

    /// First non-empty line, stripped of markdown heading marks and capped so
    /// a card never renders a paragraph as its title.
    static func headline(body: String, fallback: String) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = line.trimmingCharacters(in: .whitespaces)
            while text.hasPrefix("#") {
                text.removeFirst()
            }
            text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            return text.count > 120 ? String(text.prefix(119)) + "…" : text
        }
        return fallback
    }

    /// The feed's card style comes from the producing skill or job name —
    /// neither table records a kind, and inventing a column would make every
    /// existing row `generic` anyway.
    static func kind(for name: String) -> SkillOutputKind {
        let lowered = name.lowercased()
        if lowered.contains("contradiction") {
            return .contradictionFinding
        }
        if lowered.contains("pattern") {
            return .patternFinding
        }
        if lowered.contains("correlation") {
            return .correlationInsight
        }
        if lowered.contains("capture") {
            return .captureEnriched
        }
        if lowered.contains("weekly") || lowered.contains("memo") {
            return .weeklyMemo
        }
        if lowered.contains("daily") || lowered.contains("brief") || lowered.contains("digest") {
            return .dailyBrief
        }
        return .generic
    }

    // MARK: - Request parsing

    static func limit(_ req: Request) -> Int {
        guard let raw = req.uri.queryParameters["limit"].flatMap({ Int(String($0)) }) else {
            return defaultLimit
        }
        return max(1, min(raw, maxLimit))
    }

    static func date(_ req: Request, _ name: String) -> Date? {
        guard let raw = req.uri.queryParameters[Substring(name)].map(String.init), !raw.isEmpty else { return nil }
        return HermesDates.parse(raw)
    }
}
