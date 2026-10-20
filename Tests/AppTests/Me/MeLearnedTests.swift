@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import LuminaVaultShared
import SQLKit
import Testing

/// `GET /v1/me/learned`: proposed SOUL.md changes and unconfirmed preference /
/// decision memories since `since`, for the caller only.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct MeLearnedTests {
    private struct Account {
        let userID: UUID
        let token: String
    }

    private static let day: TimeInterval = 24 * 60 * 60

    private static func register(client: some TestClientProtocol) async throws -> Account {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(
            string: #"{"email":"learned-\#(suffix)@test.luminavault","username":"learned\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
        )
        let auth = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)) }
        return Account(userID: auth.userId, token: auth.accessToken)
    }

    private static func learned(
        client: some TestClientProtocol,
        token: String,
        query: String = ""
    ) async throws -> (HTTPResponse.Status, LearnedDigestResponse?) {
        try await client.execute(
            uri: "/v1/me/learned\(query)",
            method: .get,
            headers: [.authorization: "Bearer \(token)"]
        ) { response in
            guard response.status == .ok else { return (response.status, nil) }
            return try (response.status, testJSONDecoder().decode(LearnedDigestResponse.self, from: Data(response.body.readableBytesView)))
        }
    }

    @discardableResult
    static func memory(
        fluent: Fluent,
        tenantID: UUID,
        content: String,
        createdAt: Date,
        kind: MemoryKindDTO?,
        reviewState: String = MemoryReviewState.auto
    ) async throws -> UUID {
        let id = try await MemoryRepository(fluent: fluent).create(
            tenantID: tenantID,
            content: content,
            embedding: DeterministicEmbeddingService().embed(content, tenantID: tenantID),
            reviewState: reviewState,
            contribution: .legacy,
            kind: kind
        ).requireID()
        let sql = try #require(fluent.db() as? any SQLDatabase)
        try await sql.raw("UPDATE memories SET created_at = \(bind: createdAt) WHERE id = \(bind: id)").run()
        return id
    }

    @discardableResult
    static func soulChange(
        fluent: Fluent,
        tenantID: UUID,
        title: String,
        createdAt: Date,
        kind: String = "soul",
        state: String = "pending"
    ) async throws -> UUID {
        let id = UUID()
        let sql = try #require(fluent.db() as? any SQLDatabase)
        try await sql.raw("""
        INSERT INTO self_improvement_changes (id, tenant_id, kind, state, trigger, title, summary, created_at)
        VALUES (\(bind: id), \(bind: tenantID), \(bind: kind), \(bind: state), 'weekly', \(bind: title), \(bind: "Summary of \(title)"), \(bind: createdAt))
        """).run()
        return id
    }

    private static func isoQuery(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "?since=" + formatter.string(from: date)
    }

    // MARK: - Filtering

    @Test
    func `soul changes are the caller's pending soul proposals since since`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let me = try await Self.register(client: client)
            let other = try await Self.register(client: client)
            let now = Date()
            let ids = try await withTestFluent(label: "test.learned.soul") { fluent in
                let older = try await Self.soulChange(fluent: fluent, tenantID: me.userID, title: "Prefers mornings", createdAt: now.addingTimeInterval(-2 * Self.day))
                let newer = try await Self.soulChange(fluent: fluent, tenantID: me.userID, title: "Runs on Sundays", createdAt: now.addingTimeInterval(-1 * Self.day))
                try await Self.soulChange(fluent: fluent, tenantID: me.userID, title: "Approved", createdAt: now.addingTimeInterval(-Self.day), state: "approved")
                try await Self.soulChange(fluent: fluent, tenantID: me.userID, title: "Rejected", createdAt: now.addingTimeInterval(-Self.day), state: "rejected")
                try await Self.soulChange(fluent: fluent, tenantID: me.userID, title: "Curator", createdAt: now.addingTimeInterval(-Self.day), kind: "curator")
                try await Self.soulChange(fluent: fluent, tenantID: me.userID, title: "Too old", createdAt: now.addingTimeInterval(-10 * Self.day))
                try await Self.soulChange(fluent: fluent, tenantID: other.userID, title: "Not mine", createdAt: now.addingTimeInterval(-Self.day))
                return [newer, older]
            }

            let (status, digest) = try await Self.learned(client: client, token: me.token)
            #expect(status == .ok)
            #expect(digest?.soulChanges.map(\.id) == ids)
            #expect(digest?.soulChanges.first?.title == "Runs on Sundays")
            #expect(digest?.soulChanges.first?.summary == "Summary of Runs on Sundays")
            #expect(digest?.memories.isEmpty == true)

            // A narrower window drops the older proposal.
            let (_, narrow) = try await Self.learned(client: client, token: me.token, query: Self.isoQuery(now.addingTimeInterval(-1.5 * Self.day)))
            #expect(narrow?.soulChanges.map(\.id) == [ids[0]])
        }
    }

    @Test
    func `memories are unconfirmed preferences and decisions since since`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let me = try await Self.register(client: client)
            let other = try await Self.register(client: client)
            let now = Date()
            let long = "Prefers\n  quiet   mornings " + String(repeating: "and long walks ", count: 20)
            let (preference, decision) = try await withTestFluent(label: "test.learned.memories") { fluent in
                let preference = try await Self.memory(fluent: fluent, tenantID: me.userID, content: long, createdAt: now.addingTimeInterval(-3 * Self.day), kind: .preference)
                let decision = try await Self.memory(fluent: fluent, tenantID: me.userID, content: "Chose the cheaper flat", createdAt: now.addingTimeInterval(-1 * Self.day), kind: .decision, reviewState: MemoryReviewState.pending)
                try await Self.memory(fluent: fluent, tenantID: me.userID, content: "A fact", createdAt: now.addingTimeInterval(-Self.day), kind: .fact)
                try await Self.memory(fluent: fluent, tenantID: me.userID, content: "No kind", createdAt: now.addingTimeInterval(-Self.day), kind: nil)
                try await Self.memory(fluent: fluent, tenantID: me.userID, content: "Already kept", createdAt: now.addingTimeInterval(-Self.day), kind: .preference, reviewState: MemoryReviewState.approved)
                try await Self.memory(fluent: fluent, tenantID: me.userID, content: "Forgotten", createdAt: now.addingTimeInterval(-Self.day), kind: .decision, reviewState: MemoryReviewState.rejected)
                try await Self.memory(fluent: fluent, tenantID: me.userID, content: "Too old", createdAt: now.addingTimeInterval(-8 * Self.day), kind: .decision)
                try await Self.memory(fluent: fluent, tenantID: other.userID, content: "Not mine", createdAt: now.addingTimeInterval(-Self.day), kind: .preference)
                return (preference, decision)
            }

            let (status, digest) = try await Self.learned(client: client, token: me.token)
            #expect(status == .ok)
            let memories = try #require(digest?.memories)
            #expect(memories.map(\.id) == [decision, preference])
            #expect(memories.map(\.kind) == ["decision", "preference"])
            #expect(memories.map(\.reviewState) == [MemoryReviewState.pending, MemoryReviewState.auto])
            let snippet = memories[1].snippet
            #expect(snippet.count <= 160)
            #expect(!snippet.contains("\n"))
            #expect(snippet.hasPrefix("Prefers quiet mornings and long walks"))
            #expect(digest?.soulChanges.isEmpty == true)
            #expect(digest?.isEmpty == false)

            // Default window is seven days.
            let since = try #require(digest?.since)
            let until = try #require(digest?.until)
            #expect(abs(until.timeIntervalSince(since) - 7 * Self.day) < 1)
        }
    }

    @Test
    func `memories are capped at twenty, newest first`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let me = try await Self.register(client: client)
            let now = Date()
            let ids = try await withTestFluent(label: "test.learned.limit") { fluent in
                var ids: [UUID] = []
                for index in 0 ..< 25 {
                    try await ids.append(Self.memory(
                        fluent: fluent,
                        tenantID: me.userID,
                        content: "Preference \(index)",
                        createdAt: now.addingTimeInterval(-Double(index + 1) * 600),
                        kind: .preference
                    ))
                }
                return ids
            }
            let (_, digest) = try await Self.learned(client: client, token: me.token)
            #expect(digest?.memories.map(\.id) == Array(ids.prefix(20)))
        }
    }

    // MARK: - since

    @Test
    func `bad since is a 400`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let me = try await Self.register(client: client)
            for query in [
                "?since=yesterday",
                Self.isoQuery(Date().addingTimeInterval(Self.day)),
                Self.isoQuery(Date().addingTimeInterval(-91 * Self.day)),
            ] {
                let (status, _) = try await Self.learned(client: client, token: me.token, query: query)
                #expect(status == .badRequest, "\(query)")
            }
            let (ok, digest) = try await Self.learned(client: client, token: me.token, query: "?since=" + ISO8601DateFormatter().string(from: Date().addingTimeInterval(-89 * Self.day)))
            #expect(ok == .ok)
            #expect(digest?.isEmpty == true)
        }
    }

    @Test
    func `requires a token`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/me/learned", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `parseSince accepts offsets and fractional seconds`() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-18T18:00:00Z"))
        #expect(try MeLearnedController.parseSince(nil, now: now) == now.addingTimeInterval(-7 * Self.day))
        #expect(try MeLearnedController.parseSince("2026-10-12T00:00:00Z", now: now) == ISO8601DateFormatter().date(from: "2026-10-12T00:00:00Z"))
        #expect(try MeLearnedController.parseSince("2026-10-12T01:00:00 01:00", now: now) == ISO8601DateFormatter().date(from: "2026-10-12T00:00:00Z"))
        #expect(try MeLearnedController.parseSince("2026-10-12T00:00:00.500Z", now: now).timeIntervalSince1970.truncatingRemainder(dividingBy: 1) == 0.5)
        #expect(throws: HTTPError.self) { try MeLearnedController.parseSince("2026-10-19T00:00:00Z", now: now) }
    }
}
