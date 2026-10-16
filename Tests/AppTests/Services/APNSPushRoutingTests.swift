@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit
import Testing

/// Per-device APNs topic, the extra `aps` fields `notify` can carry, and the
/// one-proactive-push-a-day budget.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct APNSPushRoutingTests {
    private static let configured = "com.lumina.fernando"

    private static func makeUser(fluent: Fluent, timezone: String = "UTC") async throws -> User {
        let slug = "push\(UUID().uuidString.prefix(8).lowercased())"
        let user = User(email: "\(slug)@test.luminavault", username: slug, passwordHash: "stub-\(slug)")
        user.timezone = timezone
        try await user.save(on: fluent.db())
        try await DefaultAuthService.ensurePersonalVault(for: user, on: fluent.db())
        return user
    }

    private static func service(_ fluent: Fluent, _ push: RecordingPushSender) -> APNSNotificationService {
        APNSNotificationService(bundleID: configured, fluent: fluent, pushSender: push, logger: Logger(label: "test.apns.routing"))
    }

    @Test
    func `each device is pushed under its own bundle id`() async throws {
        try await withTestFluent(label: "test.apns.topic") { fluent in
            let userID = try await Self.makeUser(fluent: fluent).requireID()
            let beta = "beta-\(UUID().uuidString)"
            let legacy = "legacy-\(UUID().uuidString)"
            let stale = "stale-\(UUID().uuidString)"
            try await DeviceToken(tenantID: userID, token: beta, platform: "ios", bundleID: "com.lumina.fernando.beta").save(on: fluent.db())
            try await DeviceToken(tenantID: userID, token: legacy, platform: "ios").save(on: fluent.db())
            // A stored id that is no longer allowed falls back to the configured one.
            try await DeviceToken(tenantID: userID, token: stale, platform: "ios", bundleID: "com.other.app").save(on: fluent.db())

            let push = RecordingPushSender()
            try await Self.service(fluent, push).notify(userID: userID, title: "t", subtitle: nil, body: "b", category: .reminder)

            let topics = await Dictionary(uniqueKeysWithValues: push.sends.map { ($0.token, $0.topic) })
            #expect(topics[beta] == "com.lumina.fernando.beta")
            #expect(topics[legacy] == Self.configured)
            #expect(topics[stale] == Self.configured)
        }
    }

    @Test
    func `a token rejected for its topic is still reaped`() async throws {
        try await withTestFluent(label: "test.apns.reap") { fluent in
            let userID = try await Self.makeUser(fluent: fluent).requireID()
            let dead = "dead-\(UUID().uuidString)"
            try await DeviceToken(tenantID: userID, token: dead, platform: "ios", bundleID: "com.lumina.fernando.beta").save(on: fluent.db())
            let push = RecordingPushSender()
            await push.failOn(token: dead, with: "DeviceTokenNotForTopic")
            try await Self.service(fluent, push).notify(userID: userID, title: "t", subtitle: nil, body: "b", category: .reminder)
            #expect(try await DeviceToken.query(on: fluent.db()).filter(\.$token == dead).count() == 0)
        }
    }

    @Test
    func `default options keep today's aps fields`() async throws {
        try await withTestFluent(label: "test.apns.defaults") { fluent in
            let userID = try await Self.makeUser(fluent: fluent).requireID()
            try await DeviceToken(tenantID: userID, token: UUID().uuidString, platform: "ios").save(on: fluent.db())
            let push = RecordingPushSender()
            try await Self.service(fluent, push).notify(userID: userID, title: "t", subtitle: nil, body: "b", category: .digest)
            let send = try #require(await push.sends.first)
            #expect(send.options == APNSPushOptions(apsCategory: "digest"))
            #expect(send.options.interruptionLevel == nil)
            #expect(send.options.threadID == nil)
        }
    }

    @Test
    func `interruption level, thread id and action category pass through`() async throws {
        try await withTestFluent(label: "test.apns.options") { fluent in
            let userID = try await Self.makeUser(fluent: fluent).requireID()
            try await DeviceToken(tenantID: userID, token: UUID().uuidString, platform: "ios").save(on: fluent.db())
            let push = RecordingPushSender()
            try await Self.service(fluent, push).notify(
                userID: userID, title: "t", subtitle: nil, body: "b", category: .digest,
                interruptionLevel: .passive, threadID: "resurface", actionCategory: "digest.review"
            )
            let send = try #require(await push.sends.first)
            #expect(send.options.apsCategory == "digest.review")
            #expect(send.options.interruptionLevel == .passive)
            #expect(send.options.threadID == "resurface")
            // The base category still names the push in the custom payload path.
            #expect(send.category == .digest)
        }
    }

    @Test
    func `opt-out gating uses the base category, not the action category`() async throws {
        try await withTestFluent(label: "test.apns.gating") { fluent in
            let userID = try await Self.makeUser(fluent: fluent).requireID()
            try await DeviceToken(tenantID: userID, token: UUID().uuidString, platform: "ios").save(on: fluent.db())
            try await ApnsCategoryPrefs(tenantID: userID, digestEnabled: false).save(on: fluent.db())
            let push = RecordingPushSender()
            let service = Self.service(fluent, push)
            // Digest is off: an actionable variant of it is off too.
            try await service.notify(userID: userID, title: "t", subtitle: nil, body: "b", category: .digest, actionCategory: "chat")
            #expect(await push.sends.isEmpty)
            // Chat is on: an action category named after a muted one does not mute it.
            try await service.notify(userID: userID, title: "t", subtitle: nil, body: "b", category: .chat, actionCategory: "digest")
            #expect(await push.sends.count == 1)
        }
    }

    @Test
    func `interruption levels map to the APNs strings`() {
        #expect(APNSPushInterruptionLevel.passive.apns == .passive)
        #expect(APNSPushInterruptionLevel.active.apns == .active)
        #expect(APNSPushInterruptionLevel.timeSensitive.apns == .timeSensitive)
    }

    // MARK: - Proactive budget

    @Test
    func `one proactive push per tenant per local day`() async throws {
        try await withTestFluent(label: "test.apns.budget") { fluent in
            let budget = ProactivePushBudget(fluent: fluent)
            let lisbon = try await Self.makeUser(fluent: fluent, timezone: "Europe/Lisbon").requireID()
            let other = try await Self.makeUser(fluent: fluent).requireID()
            let morning = ISO8601DateFormatter().date(from: "2026-10-16T08:00:00Z")!
            let evening = ISO8601DateFormatter().date(from: "2026-10-16T21:00:00Z")!
            let nextDay = ISO8601DateFormatter().date(from: "2026-10-17T08:00:00Z")!

            #expect(try await budget.claim(tenantID: lisbon, kind: "learned_digest", timezone: "Europe/Lisbon", now: morning))
            #expect(try await !budget.claim(tenantID: lisbon, kind: "daily_brief", timezone: "Europe/Lisbon", now: evening))
            #expect(try await budget.claim(tenantID: other, kind: "daily_brief", timezone: "UTC", now: evening))
            #expect(try await budget.claim(tenantID: lisbon, kind: "daily_brief", timezone: "Europe/Lisbon", now: nextDay))
        }
    }

    @Test
    func `the budget day is the user's local day`() async throws {
        try await withTestFluent(label: "test.apns.budget.tz") { fluent in
            let budget = ProactivePushBudget(fluent: fluent)
            let tenant = try await Self.makeUser(fluent: fluent, timezone: "America/Los_Angeles").requireID()
            // 23:00 UTC on the 16th and 06:00 UTC on the 17th are both the 16th in Los Angeles.
            let late = ISO8601DateFormatter().date(from: "2026-10-16T23:00:00Z")!
            let afterUTCMidnight = ISO8601DateFormatter().date(from: "2026-10-17T06:00:00Z")!
            #expect(try await budget.claim(tenantID: tenant, kind: "learned_digest", timezone: "America/Los_Angeles", now: late))
            #expect(try await !budget.claim(tenantID: tenant, kind: "learned_digest", timezone: "America/Los_Angeles", now: afterUTCMidnight))
            #expect(ProactivePushBudget.localDay(afterUTCMidnight, timezone: "America/Los_Angeles") == "2026-10-16")
            #expect(ProactivePushBudget.localDay(afterUTCMidnight, timezone: "Not/AZone") == "2026-10-17")
        }
    }
}
