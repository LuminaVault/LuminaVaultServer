@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import LuminaVaultShared
import SQLKit
import Testing

/// Resurfacing: `POST /v1/memory/{id}/review` actions schedule or mute a
/// memory, and `GET /v1/me/resurface` picks due, on-this-day and fading
/// memories on the user's own calendar, never offering the excluded ones.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct MeResurfaceTests {
    private struct Account {
        let userID: UUID
        let token: String
    }

    private static let day: TimeInterval = 24 * 60 * 60

    private static func register(client: some TestClientProtocol) async throws -> Account {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(
            string: #"{"email":"resurface-\#(suffix)@test.luminavault","username":"resurface\#(suffix)","password":"CorrectHorseBatteryStaple1!"}"#
        )
        let auth = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { try testJSONDecoder().decode(AuthResponse.self, from: Data($0.body.readableBytesView)) }
        return Account(userID: auth.userId, token: auth.accessToken)
    }

    private static func review(
        client: some TestClientProtocol,
        token: String,
        id: UUID,
        body: String? = nil
    ) async throws -> (HTTPResponse.Status, MemoryReviewResponse?) {
        var headers: HTTPFields = [.authorization: "Bearer \(token)"]
        if body != nil {
            headers[.contentType] = "application/json"
        }
        return try await client.execute(
            uri: "/v1/memory/\(id)/review",
            method: .post,
            headers: headers,
            body: body.map { ByteBuffer(string: $0) }
        ) { response in
            guard response.status == .ok else { return (response.status, nil) }
            return try (response.status, testJSONDecoder().decode(MemoryReviewResponse.self, from: Data(response.body.readableBytesView)))
        }
    }

    private static func resurface(
        client: some TestClientProtocol,
        token: String,
        query: String = ""
    ) async throws -> (HTTPResponse.Status, ResurfaceResponse?) {
        try await client.execute(
            uri: "/v1/me/resurface\(query)",
            method: .get,
            headers: [.authorization: "Bearer \(token)"]
        ) { response in
            guard response.status == .ok else { return (response.status, nil) }
            return try (response.status, testJSONDecoder().decode(ResurfaceResponse.self, from: Data(response.body.readableBytesView)))
        }
    }

    /// A memory with its timestamps set directly.
    @discardableResult
    private static func memory(
        fluent: Fluent,
        tenantID: UUID,
        content: String,
        createdAt: Date,
        kind: MemoryKindDTO? = nil,
        reviewState: String = MemoryReviewState.auto,
        contribution: MemoryContributionInput = .legacy,
        lastReviewedAt: Date? = nil,
        nextReviewAt: Date? = nil,
        muted: Bool = false
    ) async throws -> UUID {
        let id = try await MemoryRepository(fluent: fluent).create(
            tenantID: tenantID,
            content: content,
            embedding: DeterministicEmbeddingService().embed(content, tenantID: tenantID),
            reviewState: reviewState,
            contribution: contribution,
            kind: kind
        ).requireID()
        let sql = try #require(fluent.db() as? any SQLDatabase)
        try await sql.raw("""
        UPDATE memories
        SET created_at = \(bind: createdAt),
            last_reviewed_at = \(bind: lastReviewedAt),
            next_review_at = \(bind: nextReviewAt),
            resurface_muted = \(bind: muted)
        WHERE id = \(bind: id)
        """).run()
        return id
    }

    private static func makeUser(fluent: Fluent, timezone: String) async throws -> User {
        let slug = "rs\(UUID().uuidString.prefix(8).lowercased())"
        let user = User(email: "\(slug)@test.luminavault", username: slug, passwordHash: "stub-\(slug)")
        user.timezone = timezone
        try await user.save(on: fluent.db())
        try await DefaultAuthService.ensurePersonalVault(for: user, on: fluent.db())
        return user
    }

    private static func iso(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    // MARK: - Review actions

    @Test
    func `review actions schedule, clear and mute while no body stays as before`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let account = try await Self.register(client: client)
            let id = try await withTestFluent(label: "test.resurface.review") { fluent in
                try await Self.memory(fluent: fluent, tenantID: account.userID, content: "Rent goes up in May", createdAt: Date())
            }

            // No body: exactly the old endpoint, plus the two new fields.
            let (plainStatus, plain) = try await Self.review(client: client, token: account.token, id: id)
            #expect(plainStatus == .ok)
            #expect(plain?.reviewCount == 1)
            #expect(plain?.nextReviewAt == nil)
            #expect(plain?.resurfaceMuted == false)

            let before = Date()
            let (_, soon) = try await Self.review(client: client, token: account.token, id: id, body: #"{"action":"soon"}"#)
            let soonAt = try #require(soon?.nextReviewAt)
            #expect(abs(soonAt.timeIntervalSince(before) - 3 * Self.day) < 60)
            #expect(soon?.reviewCount == 2)

            let (_, later) = try await Self.review(client: client, token: account.token, id: id, body: #"{"action":"later"}"#)
            let laterAt = try #require(later?.nextReviewAt)
            #expect(abs(laterAt.timeIntervalSince(before) - 30 * Self.day) < 60)

            let (_, kept) = try await Self.review(client: client, token: account.token, id: id, body: #"{"action":"kept"}"#)
            #expect(kept?.nextReviewAt == nil)
            #expect(kept?.resurfaceMuted == false)

            let (_, never) = try await Self.review(client: client, token: account.token, id: id, body: #"{"action":"never"}"#)
            #expect(never?.nextReviewAt == nil)
            #expect(never?.resurfaceMuted == true)
            #expect(never?.reviewCount == 5)

            let (badStatus, _) = try await Self.review(client: client, token: account.token, id: id, body: #"{"action":"someday"}"#)
            #expect(badStatus == .badRequest)

            try await withTestFluent(label: "test.resurface.review.check") { fluent in
                let row = try #require(try await Memory.find(id, on: fluent.db()))
                #expect(row.resurfaceMuted)
                #expect(row.nextReviewAt == nil)
                #expect(row.reviewCount == 5)
                #expect(row.lastReviewedAt != nil)
                let sql = try #require(fluent.db() as? any SQLDatabase)
                struct Count: Decodable { let n: Int }
                let events = try await sql.raw("""
                SELECT COUNT(*)::int AS n FROM analytics_events
                WHERE vault_id = \(bind: account.userID) AND event_name = 'memory_reviewed'
                """).first(decoding: Count.self)
                #expect(events?.n == 5)
            }

            // Another tenant cannot review it.
            let stranger = try await Self.register(client: client)
            let (foreign, _) = try await Self.review(client: client, token: stranger.token, id: id, body: #"{"action":"soon"}"#)
            #expect(foreign == .notFound)
        }
    }

    // MARK: - GET /v1/me/resurface

    @Test
    func `due comes first, then fading, and everything excluded stays out`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let account = try await Self.register(client: client)
            let stranger = try await Self.register(client: client)
            let now = Date()
            let old = now.addingTimeInterval(-90 * Self.day)
            let ids = try await withTestFluent(label: "test.resurface.lanes") { fluent in
                let tenant = account.userID
                let due = try await Self.memory(
                    fluent: fluent, tenantID: tenant, content: "Call the accountant", createdAt: now.addingTimeInterval(-5 * Self.day),
                    lastReviewedAt: now.addingTimeInterval(-4 * Self.day), nextReviewAt: now.addingTimeInterval(-Self.day)
                )
                let fading = try await Self.memory(
                    fluent: fluent, tenantID: tenant, content: "We pay suppliers net 30", createdAt: old, kind: .decision
                )
                // Excluded, each for one reason.
                try await Self.memory(fluent: fluent, tenantID: tenant, content: "rejected", createdAt: old, kind: .decision,
                                      reviewState: MemoryReviewState.rejected)
                try await Self.memory(fluent: fluent, tenantID: tenant, content: "muted", createdAt: old, kind: .decision, muted: true)
                try await Self.memory(fluent: fluent, tenantID: tenant, content: "just reviewed", createdAt: old, kind: .decision,
                                      lastReviewedAt: now.addingTimeInterval(-3600), nextReviewAt: now.addingTimeInterval(-60))
                try await Self.memory(fluent: fluent, tenantID: tenant, content: "scheduled for later", createdAt: old, kind: .decision,
                                      nextReviewAt: now.addingTimeInterval(10 * Self.day))
                try await Self.memory(fluent: fluent, tenantID: tenant, content: "unapproved chat memory", createdAt: old, kind: .decision,
                                      reviewState: MemoryReviewState.pending,
                                      contribution: .model(.create, source: .chat, provider: "hermes", model: "test"))
                try await Self.memory(fluent: fluent, tenantID: tenant, content: "a fact, not fading", createdAt: old, kind: .fact)
                try await Self.memory(fluent: fluent, tenantID: stranger.userID, content: "someone else's", createdAt: old, kind: .decision,
                                      nextReviewAt: now.addingTimeInterval(-Self.day))
                return (due: due, fading: fading)
            }

            let (status, body) = try await Self.resurface(client: client, token: account.token, query: "?limit=10")
            #expect(status == .ok)
            let items = try #require(body?.items)
            #expect(items.map(\.memoryId) == [ids.due, ids.fading])
            #expect(items.first?.reason == .due)
            #expect(items.first?.why == "You asked to see this again")
            #expect(items.last?.reason == .fading)
            #expect(items.last?.kind == "decision")
            #expect(items.last?.why.hasPrefix("A decision you haven't revisited since ") == true)

            // Default limit is 3; the limit is respected and validated.
            let (_, one) = try await Self.resurface(client: client, token: account.token, query: "?limit=1")
            #expect(one?.items.map(\.memoryId) == [ids.due])
            let (zero, _) = try await Self.resurface(client: client, token: account.token, query: "?limit=0")
            #expect(zero == .badRequest)
            let (tooMany, _) = try await Self.resurface(client: client, token: account.token, query: "?limit=11")
            #expect(tooMany == .badRequest)
        }
    }

    @Test
    func `limit caps the result and a memory shows up once`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let account = try await Self.register(client: client)
            let now = Date()
            try await withTestFluent(label: "test.resurface.limit") { fluent in
                for n in 0 ..< 5 {
                    // Due *and* fading: must appear once, as due.
                    try await Self.memory(
                        fluent: fluent, tenantID: account.userID, content: "Preference \(n)",
                        createdAt: now.addingTimeInterval(-Double(100 + n) * Self.day), kind: .preference,
                        nextReviewAt: now.addingTimeInterval(-Double(n + 1) * 3600)
                    )
                }
            }
            let (_, body) = try await Self.resurface(client: client, token: account.token)
            let items = try #require(body?.items)
            #expect(items.count == 3)
            #expect(Set(items.map(\.memoryId)).count == 3)
            #expect(items.allSatisfy { $0.reason == .due })
            // Oldest due first.
            #expect(items.map(\.snippet) == ["Preference 4", "Preference 3", "Preference 2"])
        }
    }

    @Test
    func `on this day uses the user's calendar, not UTC`() async throws {
        try await withTestFluent(label: "test.resurface.tz") { fluent in
            // 12:00 UTC on 16 Oct is already 01:00 on 17 Oct in Auckland (NZDT, +13).
            let now = Self.iso("2026-10-16T12:00:00Z")
            let user = try await Self.makeUser(fluent: fluent, timezone: "Pacific/Auckland")
            let tenant = try user.requireID()
            // 00:30 on 17 Oct 2025 in Auckland — a year ago today, locally.
            let local = try await Self.memory(
                fluent: fluent, tenantID: tenant, content: "Signed the lease", createdAt: Self.iso("2025-10-16T11:30:00Z")
            )
            // 18:00 on 16 Oct 2025 in Auckland: a year ago on the *UTC* day only.
            try await Self.memory(fluent: fluent, tenantID: tenant, content: "Not today", createdAt: Self.iso("2025-10-16T05:00:00Z"))

            let response = try await MeResurfaceService(fluent: fluent).build(user: user, limit: 10, now: now)
            #expect(response.items.map(\.memoryId) == [local])
            #expect(response.items.first?.reason == .onThisDay)
            #expect(response.items.first?.why == "Saved a year ago today")
        }
    }

    @Test
    func `on this day and fading say why in words`() async throws {
        try await withTestFluent(label: "test.resurface.why") { fluent in
            let now = Self.iso("2026-10-16T12:00:00Z")
            let user = try await Self.makeUser(fluent: fluent, timezone: "UTC")
            let tenant = try user.requireID()
            let twoYears = try await Self.memory(fluent: fluent, tenantID: tenant, content: "two years", createdAt: Self.iso("2024-10-16T09:00:00Z"))
            let halfYear = try await Self.memory(fluent: fluent, tenantID: tenant, content: "six months", createdAt: Self.iso("2026-04-16T09:00:00Z"))
            let month = try await Self.memory(fluent: fluent, tenantID: tenant, content: "a month", createdAt: Self.iso("2026-09-16T09:00:00Z"))
            let preference = try await Self.memory(
                fluent: fluent, tenantID: tenant, content: "Aisle seats", createdAt: Self.iso("2026-01-02T09:00:00Z"), kind: .preference,
                lastReviewedAt: Self.iso("2026-03-14T09:00:00Z")
            )

            let items = try await MeResurfaceService(fluent: fluent).build(user: user, limit: 10, now: now).items
            #expect(items.map(\.memoryId) == [twoYears, halfYear, month, preference])
            #expect(items.map(\.why) == [
                "Saved 2 years ago today",
                "Saved 6 months ago today",
                "Saved a month ago today",
                "A preference you haven't revisited since March 2026",
            ])
            #expect(items.last?.reason == .fading)
            #expect(items.last?.kind == "preference")
        }
    }

    @Test
    func `snippet is one line of at most 160 characters`() async throws {
        try await withTestFluent(label: "test.resurface.snippet") { fluent in
            let now = Self.iso("2026-10-16T12:00:00Z")
            let user = try await Self.makeUser(fluent: fluent, timezone: "UTC")
            let long = "First line\nsecond " + String(repeating: "word ", count: 80)
            try await Self.memory(
                fluent: fluent, tenantID: user.requireID(), content: long, createdAt: Self.iso("2025-10-16T09:00:00Z")
            )
            let item = try #require(try await MeResurfaceService(fluent: fluent).build(user: user, limit: 3, now: now).items.first)
            #expect(item.snippet.count <= 160)
            #expect(!item.snippet.contains("\n"))
            #expect(item.snippet.hasPrefix("First line second"))
        }
    }

    @Test
    func `limit parsing`() throws {
        #expect(try MeResurfaceController.parseLimit(nil) == 3)
        #expect(try MeResurfaceController.parseLimit("10") == 10)
        #expect(throws: HTTPError.self) { try MeResurfaceController.parseLimit("abc") }
        #expect(throws: HTTPError.self) { try MeResurfaceController.parseLimit("0") }
    }
}
