@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import LuminaVaultShared
import SQLKit
import Testing

/// HER-177 / Hermes Phase 2 — the pure shaping helpers behind
/// `GET /v1/skills/outputs`. No database: every function here is a total
/// function of its arguments, so the cheap suite covers the branches the
/// Postgres suite below would only reach by contriving rows.
struct SkillOutputsShapingTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private static let today = Date(timeIntervalSince1970: 1_756_800_000) // 2025-09-02T08:00:00Z

    private static func day(_ offset: Int) -> Date {
        utc.date(byAdding: .day, value: offset, to: utc.startOfDay(for: today)) ?? today
    }

    @Test
    func `no runs at all is a zero streak`() {
        #expect(SkillOutputsController.streakLength(days: [], today: Self.today) == 0)
    }

    @Test
    func `a run today starts the streak and consecutive days extend it`() {
        #expect(SkillOutputsController.streakLength(days: [Self.day(0)], today: Self.today) == 1)
        #expect(SkillOutputsController.streakLength(days: [Self.day(0), Self.day(-1), Self.day(-2)], today: Self.today) == 3)
        // Any time of day counts; the query truncates to a day, so a run at
        // 23:59 UTC must not land on the next day's bucket.
        let lateYesterday = Self.day(-1).addingTimeInterval(86399)
        #expect(SkillOutputsController.streakLength(days: [Self.day(0), lateYesterday], today: Self.today) == 2)
    }

    @Test
    func `a streak survives a day that has not produced anything yet`() {
        // Today is still young: yesterday alone is a live 1-day streak, and
        // the days behind it still count.
        #expect(SkillOutputsController.streakLength(days: [Self.day(-1)], today: Self.today) == 1)
        #expect(SkillOutputsController.streakLength(days: [Self.day(-1), Self.day(-2)], today: Self.today) == 2)
    }

    @Test
    func `a gap breaks the streak`() {
        // Nothing today or yesterday — the streak is over regardless of history.
        #expect(SkillOutputsController.streakLength(days: [Self.day(-2), Self.day(-3)], today: Self.today) == 0)
        // A hole two days back stops the count at the hole.
        #expect(SkillOutputsController.streakLength(days: [Self.day(0), Self.day(-1), Self.day(-3)], today: Self.today) == 2)
    }

    @Test
    func `kind comes from the producing skill or job name`() {
        #expect(SkillOutputsController.kind(for: "Contradiction Scan") == .contradictionFinding)
        #expect(SkillOutputsController.kind(for: "pattern-finder") == .patternFinding)
        #expect(SkillOutputsController.kind(for: "Correlation hunter") == .correlationInsight)
        #expect(SkillOutputsController.kind(for: "capture-enrich") == .captureEnriched)
        #expect(SkillOutputsController.kind(for: "Weekly Memo") == .weeklyMemo)
        #expect(SkillOutputsController.kind(for: "luminavault-daily-brief") == .dailyBrief)
        #expect(SkillOutputsController.kind(for: "Morning digest") == .dailyBrief)
        #expect(SkillOutputsController.kind(for: "luminavault-nightly-compile") == .generic)
    }

    @Test
    func `the headline is the first meaningful line, unmarked and capped`() {
        #expect(SkillOutputsController.headline(body: "## Tuesday brief\n\nAll quiet.", fallback: "x") == "Tuesday brief")
        #expect(SkillOutputsController.headline(body: "\n\n  # Spaced  \nrest", fallback: "x") == "Spaced")
        #expect(SkillOutputsController.headline(body: "   \n\n", fallback: "Digest") == "Digest")
        let long = String(repeating: "a", count: 200)
        let headline = SkillOutputsController.headline(body: long, fallback: "x")
        #expect(headline.count == 120)
        #expect(headline.hasSuffix("…"))
    }

    private func row(
        name: String,
        status: String,
        error: String?,
        markdown: String?,
        source: String = SkillSource.hermes.rawValue
    ) -> SkillOutputsController.FeedRow {
        SkillOutputsController.FeedRow(
            id: UUID(), name: name, source: source,
            started_at: Self.today, status: status, error: error, markdown: markdown, vault_path: nil
        )
    }

    @Test
    func `a failed run with no markdown falls back to the error text`() {
        let output = SkillOutputsController.output(
            row(name: "Daily Digest", status: HermesJobRunStatus.error.rawValue, error: "provider timeout", markdown: nil)
        )
        #expect(output.headline == "Daily Digest failed")
        #expect(output.body == "provider timeout")
        #expect(output.source == .hermes)

        // A failed run that still produced markdown keeps its own headline —
        // the body is the useful half of a partial failure.
        let partial = SkillOutputsController.output(
            row(name: "Daily Digest", status: HermesJobRunStatus.error.rawValue, error: "truncated", markdown: "# Half a brief\n")
        )
        #expect(partial.headline == "Half a brief")
        #expect(partial.body == "# Half a brief\n")
    }

    @Test
    func `an unknown source degrades to builtin rather than dropping the row`() {
        let output = SkillOutputsController.output(row(name: "n", status: "success", error: nil, markdown: "# hi", source: "from-the-future"))
        #expect(output.source == .builtin)
    }
}

/// HER-177 / Hermes Phase 2 — `GET /v1/skills/outputs` against a real
/// Postgres: the union of local `skill_run_log` runs and collected
/// `hermes_job_runs`, its ordering, paging and the streak / active-run flags.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct SkillOutputsFeedTests {
    private struct Registration {
        let token: String
        let tenantID: UUID
        var auth: HTTPFields {
            [.authorization: "Bearer \(token)", .contentType: "application/json"]
        }
    }

    private static func register(client: some TestClientProtocol) async throws -> Registration {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(string: """
        {"email":"outputs-\(suffix)@test.luminavault","username":"outputs-\(suffix)","password":"CorrectHorseBatteryStaple1!"}
        """)
        let response = try await client.execute(uri: "/v1/auth/register", method: .post, headers: [.contentType: "application/json"], body: body) {
            try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: $0.body))
        }
        return Registration(token: response.accessToken, tenantID: response.userId)
    }

    private static func feed(_ client: some TestClientProtocol, _ registration: Registration, query: String = "") async throws -> SkillOutputListResponse {
        try await client.execute(uri: "/v1/skills/outputs\(query)", method: .get, headers: registration.auth) { response in
            #expect(response.status == .ok)
            return try testJSONDecoder().decode(SkillOutputListResponse.self, from: Data(buffer: response.body))
        }
    }

    /// `2025-09-02T08:00:00Z` plus `hours`.
    private static func at(_ hours: Double) -> Date {
        Date(timeIntervalSince1970: 1_756_800_000 + hours * 3600)
    }

    /// A local `skill_run_log` row. That table has no Fluent model.
    private static func seedLocalRun(
        on sql: any SQLDatabase,
        tenantID: UUID,
        name: String,
        at startedAt: Date,
        markdown: String?,
        status: SkillRunStatus = .success,
        source: SkillSource = .builtin
    ) async throws {
        try await sql.raw("""
        INSERT INTO skill_run_log
            (id, tenant_id, source, name, started_at, ended_at, status, error, mtok_in, mtok_out, markdown)
        VALUES
            (\(bind: UUID()), \(bind: tenantID), \(bind: source.rawValue), \(bind: name), \(bind: startedAt),
             \(bind: startedAt), \(bind: status.rawValue), \(bind: nil as String?), 0, 0, \(bind: markdown))
        """).run()
    }

    @discardableResult
    private static func seedJobRun(
        on db: any Database,
        tenantID: UUID,
        jobID: String,
        key: String,
        at startedAt: Date,
        status: HermesJobRunStatus = .ok,
        output: String? = nil,
        error: String? = nil,
        vaultFileID: UUID? = nil
    ) async throws -> HermesJobRun {
        let row = HermesJobRun(
            tenantID: tenantID,
            jobID: jobID,
            run: HermesMirrorJobRun(key: key, status: status, startedAt: startedAt, finishedAt: startedAt.addingTimeInterval(60), error: error),
            collectedAt: startedAt
        )
        row.output = output
        row.vaultFileID = vaultFileID
        try await row.save(on: db)
        return row
    }

    private static func seedMirroredJob(on db: any Database, tenantID: UUID, jobID: String, name: String) async throws {
        try await HermesMirroredJob(
            tenantID: tenantID,
            job: HermesMirrorJob(id: jobID, name: name, schedule: "0 9 * * *", prompt: "p", paused: false, lastRunAt: nil, nextRunAt: nil, raw: .object([:]))
        ).save(on: db)
    }

    @Test
    func `unauthenticated requests are rejected`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/skills/outputs", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `the feed unions both sources newest first and respects limit`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let me = try await Self.register(client: client)
            try await withTestFluent(label: "lv.test.skill.outputs.union") { fluent in
                let sql = try #require(fluent.db() as? any SQLDatabase)
                try await Self.seedMirroredJob(on: fluent.db(), tenantID: me.tenantID, jobID: "j1", name: "Daily Digest")
                try await Self.seedLocalRun(on: sql, tenantID: me.tenantID, name: "capture-enrich", at: Self.at(0), markdown: "# Oldest local\n")
                try await Self.seedJobRun(on: fluent.db(), tenantID: me.tenantID, jobID: "j1", key: "r1", at: Self.at(1), output: "# Second\n")
                try await Self.seedLocalRun(on: sql, tenantID: me.tenantID, name: "weekly-memo", at: Self.at(2), markdown: "# Third\n")
                try await Self.seedJobRun(on: fluent.db(), tenantID: me.tenantID, jobID: "j1", key: "r2", at: Self.at(3), output: "# Newest\n")
                // Noise that must never reach the feed: a local run with no
                // markdown, and the `hermes` mirror of a collected job run
                // (the job-runs arm already carries it, with the vault path).
                try await Self.seedLocalRun(on: sql, tenantID: me.tenantID, name: "silent", at: Self.at(4), markdown: nil)
                try await Self.seedLocalRun(on: sql, tenantID: me.tenantID, name: "Daily Digest", at: Self.at(3), markdown: "# Newest\n", source: .hermes)
            }

            let all = try await Self.feed(client, me)
            #expect(all.outputs.map(\.headline) == ["Newest", "Third", "Second", "Oldest local"])
            #expect(all.nextCursor == nil)
            #expect(all.activeRun == false)

            let capped = try await Self.feed(client, me, query: "?limit=2")
            #expect(capped.outputs.map(\.headline) == ["Newest", "Third"])
            #expect(capped.nextCursor != nil)
        }
    }

    @Test
    func `since and before are exclusive and the cursor pages a full result`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let me = try await Self.register(client: client)
            try await withTestFluent(label: "lv.test.skill.outputs.paging") { fluent in
                let sql = try #require(fluent.db() as? any SQLDatabase)
                try await Self.seedMirroredJob(on: fluent.db(), tenantID: me.tenantID, jobID: "j1", name: "Digest")
                for hour in 0 ..< 4 {
                    try await Self.seedLocalRun(on: sql, tenantID: me.tenantID, name: "local", at: Self.at(Double(hour)), markdown: "# L\(hour)\n")
                    try await Self.seedJobRun(on: fluent.db(), tenantID: me.tenantID, jobID: "j1", key: "r\(hour)", at: Self.at(Double(hour) + 0.5), output: "# H\(hour)\n")
                }
            }

            // Page 1 of 8 rows, then follow the cursor. `before` is exclusive,
            // so the pages must not overlap and must cover everything.
            let first = try await Self.feed(client, me, query: "?limit=3")
            #expect(first.outputs.map(\.headline) == ["H3", "L3", "H2"])
            let cursor = try #require(first.nextCursor)
            #expect(HermesDates.parse(cursor) == first.outputs.last?.createdAt)

            let second = try await Self.feed(client, me, query: "?limit=3&before=\(cursor)")
            #expect(second.outputs.map(\.headline) == ["L2", "H1", "L1"])
            let secondCursor = try #require(second.nextCursor)
            let third = try await Self.feed(client, me, query: "?limit=3&before=\(secondCursor)")
            #expect(third.outputs.map(\.headline) == ["H0", "L0"])
            // A short page is the end of the feed — no cursor to follow.
            #expect(third.nextCursor == nil)

            // `since` is the client's "newest I have seen" and is exclusive
            // too, so re-sending the newest row's timestamp returns nothing.
            let newestAt = try #require(first.outputs.first?.createdAt)
            let sinceNewest = try await Self.feed(client, me, query: "?since=\(HermesDates.iso(newestAt))")
            #expect(sinceNewest.outputs.isEmpty)
            let sinceMiddle = try await Self.feed(client, me, query: "?since=\(HermesDates.iso(Self.at(2.5)))")
            #expect(sinceMiddle.outputs.map(\.headline) == ["H3", "L3"])
        }
    }

    @Test
    func `a collected job run surfaces as a hermes output with its vault path`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let me = try await Self.register(client: client)
            try await withTestFluent(label: "lv.test.skill.outputs.hermes") { fluent in
                try await Self.seedMirroredJob(on: fluent.db(), tenantID: me.tenantID, jobID: "j1", name: "Daily Digest")
                let file = VaultFile(
                    tenantID: me.tenantID,
                    path: "raw/jobs/daily-digest/2025-09-02-0800.md",
                    contentType: "text/markdown",
                    sizeBytes: 12,
                    sha256: String(repeating: "a", count: 64)
                )
                try await file.save(on: fluent.db())
                let fileID = try file.requireID()
                try await Self.seedJobRun(
                    on: fluent.db(), tenantID: me.tenantID, jobID: "j1", key: "cron_j1_1",
                    at: Self.at(0), output: "# Tuesday brief\n\nAll quiet.\n", vaultFileID: fileID
                )
                // A job that was never mirrored still shows up, named by its id.
                try await Self.seedJobRun(on: fluent.db(), tenantID: me.tenantID, jobID: "orphan", key: "cron_orphan_1", at: Self.at(-1), output: "# Orphan\n")
            }

            let feed = try await Self.feed(client, me)
            #expect(feed.outputs.count == 2)
            let digest = try #require(feed.outputs.first)
            #expect(digest.source == .hermes)
            #expect(digest.skillName == "Daily Digest")
            #expect(digest.kind == .dailyBrief)
            #expect(digest.headline == "Tuesday brief")
            #expect(digest.body == "# Tuesday brief\n\nAll quiet.\n")
            #expect(digest.vaultFilePath == "raw/jobs/daily-digest/2025-09-02-0800.md")
            #expect(feed.outputs[1].skillName == "orphan")
            #expect(feed.outputs[1].vaultFilePath == nil)
        }
    }

    @Test
    func `a failed job run falls back to the error text and a failed headline`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let me = try await Self.register(client: client)
            try await withTestFluent(label: "lv.test.skill.outputs.failed") { fluent in
                try await Self.seedMirroredJob(on: fluent.db(), tenantID: me.tenantID, jobID: "j1", name: "Daily Digest")
                try await Self.seedJobRun(
                    on: fluent.db(), tenantID: me.tenantID, jobID: "j1", key: "cron_j1_2",
                    at: Self.at(0), status: .error, output: nil, error: "provider timeout"
                )
            }

            let feed = try await Self.feed(client, me)
            let failed = try #require(feed.outputs.first)
            #expect(failed.headline == "Daily Digest failed")
            #expect(failed.body == "provider timeout")
            #expect(failed.source == .hermes)
        }
    }

    @Test
    func `activeRun tracks in-flight hermes runs and ignores stale local ones`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let stale = try await Self.register(client: client)
            let busy = try await Self.register(client: client)
            try await withTestFluent(label: "lv.test.skill.outputs.active") { fluent in
                let sql = try #require(fluent.db() as? any SQLDatabase)
                // Pending, but started two hours ago: a crashed run must not
                // pin the client on "thinking" forever.
                try await Self.seedLocalRun(
                    on: sql, tenantID: stale.tenantID, name: "stuck",
                    at: Date().addingTimeInterval(-7200), markdown: nil, status: .pending
                )
                // A Hermes run is in flight whenever Hermes says so — its
                // start time is Hermes' clock, so no window applies.
                try await Self.seedJobRun(
                    on: fluent.db(), tenantID: busy.tenantID, jobID: "j1", key: "cron_j1_now",
                    at: Self.at(0), status: .running
                )
            }

            let idle = try await Self.feed(client, stale)
            #expect(idle.activeRun == false)
            let running = try await Self.feed(client, busy)
            #expect(running.activeRun == true)
            // An unfinished run carries no output yet, so it stays off the feed.
            #expect(running.outputs.isEmpty)

            try await withTestFluent(label: "lv.test.skill.outputs.active.fresh") { fluent in
                let sql = try #require(fluent.db() as? any SQLDatabase)
                try await Self.seedLocalRun(
                    on: sql, tenantID: stale.tenantID, name: "running-now",
                    at: Date().addingTimeInterval(-60), markdown: nil, status: .running
                )
            }
            let fresh = try await Self.feed(client, stale)
            #expect(fresh.activeRun == true)
        }
    }

    @Test
    func `the streak counts days with output from either source`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let me = try await Self.register(client: client)
            let day: TimeInterval = 86400
            try await withTestFluent(label: "lv.test.skill.outputs.streak") { fluent in
                let sql = try #require(fluent.db() as? any SQLDatabase)
                // Today from a local run, yesterday from a Hermes job run,
                // then a hole, so the streak stops at two.
                try await Self.seedLocalRun(on: sql, tenantID: me.tenantID, name: "brief", at: Date(), markdown: "# Today\n")
                try await Self.seedJobRun(
                    on: fluent.db(), tenantID: me.tenantID, jobID: "j1", key: "y",
                    at: Date().addingTimeInterval(-day), output: "# Yesterday\n"
                )
                try await Self.seedLocalRun(on: sql, tenantID: me.tenantID, name: "brief", at: Date().addingTimeInterval(-3 * day), markdown: "# Older\n")
            }
            let feed = try await Self.feed(client, me)
            #expect(feed.streakDays == 2)
        }
    }
}
