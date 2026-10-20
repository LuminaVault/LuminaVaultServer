@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import SQLKit
import Testing

/// The Daily Post against Postgres with a scripted transport: one reply for
/// draft requests (`community-daily`), another for moderation
/// (`community-moderation`). Every test uses its own far-future Monday
/// (a curated day, so no feeds are needed) to stay clear of the others' rows
/// and of the 14-day topic cooldown.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct DailyPostWorkerTests {
    private static let body = String(repeating: "A weekly review keeps your notes honest and your week calm. ", count: 12)

    private static func draft(topic: String) -> String {
        #"{"title":"The ten-minute weekly review","body":"\#(body)","discussionQuestion":"When do you review your week?","topicKey":"\#(topic)","sourceUrls":[]}"#
    }

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private static func worker(fluent: Fluent, transport: ScriptedTransport) -> DailyPostWorker {
        let config = CommunityConfig(enabled: true, postingEnabled: true, dailyPostEnabled: true, dailyPostHourUTC: 12)
        let moderator = LLMCommunityModerator(transport: transport, model: "test", logger: Logger(label: "t"))
        let community = CommunityService(fluent: fluent, config: config, moderator: moderator, logger: Logger(label: "t"))
        return DailyPostWorker(
            fluent: fluent, community: community, transport: transport, model: "test",
            headlines: nil, config: config, logger: Logger(label: "t")
        )
    }

    private struct DayRow: Decodable {
        let status: String
        let attempts: Int
        let post_id: UUID?
        let source_kind: String?
        let topic_key: String?
    }

    private static func dayRow(_ fluent: Fluent, _ day: String) async throws -> DayRow? {
        let sql = try #require(fluent.db() as? any SQLDatabase)
        return try await sql.raw("""
        SELECT status, attempts, post_id, source_kind, topic_key FROM community_daily_posts WHERE day = \(bind: day)::date
        """).first(decoding: DayRow.self)
    }

    @Test
    func `two workers racing for the same day publish exactly one post`() async throws {
        try await withTestFluent(label: "lv.test.community.daily.race") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let transport = ScriptedTransport(draft: Self.draft(topic: "weekly-review-race"))
            let now = Self.date("2030-01-07T12:05:00Z")
            let a = Self.worker(fluent: fluent, transport: transport)
            let b = Self.worker(fluent: fluent, transport: transport)
            async let first = a.publishDaily(now: now)
            async let second = b.publishDaily(now: now)
            let outcomes = try await [first, second]

            #expect(outcomes.allSatisfy { $0.day == "2030-01-07" })
            #expect(await transport.draftCalls == 1)
            let row = try #require(try await Self.dayRow(fluent, "2030-01-07"))
            #expect(row.status == "published")
            #expect(row.source_kind == "curated")
            #expect(row.topic_key == "weekly-review-race")
            let postID = try #require(row.post_id)

            let sql = try #require(fluent.db() as? any SQLDatabase)
            struct PostRow: Decodable { let author_kind: String; let author_profile_id: UUID?; let body: String }
            let post = try #require(try await sql.raw("""
            SELECT author_kind, author_profile_id, body FROM community_posts WHERE id = \(bind: postID)
            """).first(decoding: PostRow.self))
            #expect(post.author_kind == "ai")
            #expect(post.author_profile_id == nil)
            #expect(post.body.contains("**Discuss:**"))

            // A later run the same day is a no-op.
            let again = try await a.publishDaily(now: now.addingTimeInterval(600))
            #expect(again.status == "published")
            #expect(await transport.draftCalls == 1)
        }
    }

    @Test
    func `a failing model retries, then the day is skipped`() async throws {
        try await withTestFluent(label: "lv.test.community.daily.fail") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let transport = ScriptedTransport(draft: "not json at all")
            let worker = Self.worker(fluent: fluent, transport: transport)
            let start = Self.date("2030-03-04T12:00:00Z")
            for attempt in 0 ..< 4 {
                _ = try await worker.publishDaily(now: start.addingTimeInterval(Double(attempt) * 900))
            }
            let row = try #require(try await Self.dayRow(fluent, "2030-03-04"))
            #expect(row.status == "skipped")
            #expect(row.attempts == DailyPostWorker.maxAttempts)
            #expect(row.post_id == nil)
            #expect(await transport.draftCalls == DailyPostWorker.maxAttempts)
        }
    }

    @Test
    func `a claim left behind by a crashed pod is reclaimed after thirty minutes`() async throws {
        try await withTestFluent(label: "lv.test.community.daily.stale") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let worker = Self.worker(fluent: fluent, transport: ScriptedTransport(draft: Self.draft(topic: "stale-claim")))
            let now = Self.date("2030-05-06T12:00:00Z")
            #expect(try await worker.claim(day: "2030-05-06", now: now))
            #expect(try await !worker.claim(day: "2030-05-06", now: now.addingTimeInterval(60)))
            let outcome = try await worker.publishDaily(now: now.addingTimeInterval(31 * 60))
            #expect(outcome.status == "published")
        }
    }

    @Test
    func `a moderation rejection fails the attempt instead of publishing`() async throws {
        try await withTestFluent(label: "lv.test.community.daily.reject") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let transport = ScriptedTransport(
                draft: Self.draft(topic: "rejected-topic"),
                verdict: #"{"allowed": false, "category": "other"}"#
            )
            let outcome = try await Self.worker(fluent: fluent, transport: transport).publishDaily(now: Self.date("2030-07-01T12:00:00Z"))
            #expect(outcome.status == "failed")
            #expect(outcome.postId == nil)
        }
    }

    @Test
    func `community signals need three participants and never read post bodies`() async throws {
        try await withTestFluent(label: "lv.test.community.daily.signals") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let sql = try #require(fluent.db() as? any SQLDatabase)
            var profiles: [UUID] = []
            for i in 0 ..< 3 {
                let user = User(email: "signals-\(UUID())@test.luminavault", username: "signals-\(UUID().uuidString.prefix(8))", passwordHash: "x")
                let userID = try await saveTenant(user, on: fluent.db())
                let profileID = UUID()
                try await sql.raw("""
                INSERT INTO community_profiles (id, user_id, handle, display_name, terms_version, terms_accepted_at)
                VALUES (\(bind: profileID), \(bind: userID), \(bind: "sig_\(i)_\(UUID().uuidString.prefix(6).lowercased())"), 'S', 1, now())
                """).run()
                profiles.append(profileID)
            }
            let now = Self.date("2030-09-02T12:00:00Z")
            let busy = UUID()
            let quiet = UUID()
            for (id, title) in [(busy, "Busy thread title"), (quiet, "Quiet thread title")] {
                try await sql.raw("""
                INSERT INTO community_posts (id, author_kind, author_profile_id, title, body, status, created_at, last_activity_at)
                VALUES (\(bind: id), 'user', \(bind: profiles[0]), \(bind: title), 'SECRET BODY TEXT', 'visible',
                        \(bind: now.addingTimeInterval(-3600)), \(bind: now.addingTimeInterval(-3600)))
                """).run()
            }
            for profile in profiles.dropFirst() {
                try await sql.raw("""
                INSERT INTO community_posts (id, parent_id, author_kind, author_profile_id, body, status, created_at, last_activity_at)
                VALUES (\(bind: UUID()), \(bind: busy), 'user', \(bind: profile), 'reply', 'visible',
                        \(bind: now.addingTimeInterval(-1800)), \(bind: now.addingTimeInterval(-1800)))
                """).run()
            }
            let titles = try await Self.worker(fluent: fluent, transport: ScriptedTransport(draft: ""))
                .communityThreadTitles(now: now)
            #expect(titles.contains("Busy thread title"))
            #expect(!titles.contains("Quiet thread title"))
            #expect(!titles.contains { $0.contains("SECRET") })
        }
    }
}

/// Replies by session: the Daily Post draft, or the moderator's verdict.
private actor ScriptedTransport: HermesChatTransport {
    let draft: String
    let verdict: String
    private(set) var draftCalls = 0

    init(draft: String, verdict: String = #"{"allowed": true, "category": "ok"}"#) {
        self.draft = draft
        self.verdict = verdict
    }

    nonisolated func chatCompletions(payload _: Data, sessionKey: String, sessionID _: String?) async throws -> Data {
        let content = await reply(for: sessionKey)
        let body: [String: Any] = [
            "id": "test", "model": "test",
            "choices": [["index": 0, "finish_reason": "stop", "message": ["role": "assistant", "content": content]]],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func reply(for sessionKey: String) -> String {
        if sessionKey == "community-daily" {
            draftCalls += 1
            return draft
        }
        return verdict
    }
}
