@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit
import Testing

/// Muse Chat stage C against Postgres: a skill speaking first lands in the
/// Hermie thread with `origin = proactive` and pushes; the kept location
/// fix; the Gmail half of the shared Google grant.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct MuseProactiveIntegrationTests {
    struct Harness {
        let fluent: Fluent
        let tenantID: UUID
        let username: String
        let root: URL
    }

    private static func withHarness(_ body: @Sendable (Harness) async throws -> Void) async throws {
        try await withTestFluent(label: "test.muse-proactive") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let username = "muse-\(UUID().uuidString.prefix(8).lowercased())"
            let tenantID = try await saveTenant(
                User(email: "\(username)@test.luminavault", username: username, passwordHash: "x"),
                on: fluent.db()
            )
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("lv-muse-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await body(Harness(fluent: fluent, tenantID: tenantID, username: username, root: root))
        }
    }

    private static func delivery(_ h: Harness, push: RecordingPushSender) -> ProactiveChatDelivery {
        ProactiveChatDelivery(
            fluent: h.fluent,
            apns: APNSNotificationService(
                bundleID: "com.luminavault.test",
                fluent: h.fluent,
                pushSender: push,
                logger: Logger(label: "test.muse.apns")
            ),
            logger: Logger(label: "test.muse")
        )
    }

    // MARK: - Proactive delivery

    @Test
    func `a proactive message lands in one Hermie thread and pushes a chat deep link`() async throws {
        try await Self.withHarness { h in
            try await DeviceToken(tenantID: h.tenantID, token: "tok-\(UUID().uuidString)", platform: "ios").save(on: h.fluent.db())
            let push = RecordingPushSender()
            let delivery = Self.delivery(h, push: push)

            let first = try await delivery.deliver(tenantID: h.tenantID, content: "## Good morning\nDry week ahead.", sourceLabel: "daily-brief")

            let thread = try #require(try await Conversation.find(first.conversationID, on: h.fluent.db()))
            #expect(thread.title == "Hermie")
            #expect(thread.systemKey == "hermie")
            #expect(thread.tenantID == h.tenantID)

            let stored = try #require(try await ConversationMessage.find(first.messageID, on: h.fluent.db()))
            let dto = try stored.toDTO()
            #expect(dto.role == .assistant)
            #expect(dto.origin == .proactive)
            #expect(dto.sourceLabel == "daily-brief")
            #expect(dto.content == "## Good morning\nDry week ahead.")

            // The wire carries both fields.
            let wire = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(dto)) as? [String: Any])
            #expect(wire["origin"] as? String == "proactive")
            #expect(wire["sourceLabel"] as? String == "daily-brief")

            let sends = await push.sends
            #expect(sends.count == 1)
            let sent = try #require(sends.first)
            #expect(sent.category == .chat)
            #expect(sent.title == "Hermie")
            #expect(sent.subtitle == "daily-brief")
            #expect(sent.body == "Good morning")
            #expect(sent.payload["conversationID"] == first.conversationID.uuidString)
            #expect(sent.payload["messageID"] == first.messageID.uuidString)
            #expect(sent.payload["deepLink"] == "luminavault://chat/\(first.conversationID.uuidString)")

            // Renamed by the user — the next delivery still finds it.
            thread.title = "My mornings"
            try await thread.save(on: h.fluent.db())
            let second = try await delivery.deliver(tenantID: h.tenantID, content: "Rain Thursday.", sourceLabel: "job-weather")
            #expect(second.conversationID == first.conversationID)
            let threads = try await Conversation.query(on: h.fluent.db(), tenantID: h.tenantID).all()
            #expect(threads.count == 1)
        }
    }

    @Test
    func `an ordinary turn still reads as a reply`() async throws {
        try await Self.withHarness { h in
            let conversation = Conversation(tenantID: h.tenantID, title: "Plain")
            try await conversation.save(on: h.fluent.db())
            let message = try ConversationMessage(conversationID: conversation.requireID(), role: .assistant, content: "Hi")
            try await message.save(on: h.fluent.db())
            let dto = try message.toDTO()
            #expect(dto.origin == .reply)
            #expect(dto.sourceLabel == nil)
        }
    }

    @Test
    func `a skill with a chat_message output speaks in the Hermie thread`() async throws {
        try await Self.withHarness { h in
            try await DeviceToken(tenantID: h.tenantID, token: "tok-\(UUID().uuidString)", platform: "ios").save(on: h.fluent.db())
            let push = RecordingPushSender()
            let apns = APNSNotificationService(bundleID: "com.luminavault.test", fluent: h.fluent, pushSender: push, logger: Logger(label: "t"))
            let vaultPaths = VaultPathService(rootPath: h.root.path)
            let runner = SkillRunner(
                catalog: SkillCatalog(vaultPaths: vaultPaths, logger: Logger(label: "t")),
                transport: FixedReplyTransport(content: "Five dry days from Saturday — good week to paint the fence."),
                memories: MemoryRepository(fluent: h.fluent),
                embeddings: DeterministicEmbeddingService(),
                apns: apns,
                defaultModel: "test-model",
                fluent: h.fluent,
                vaultPaths: vaultPaths,
                capGuard: SkillRunCapGuard(fluent: h.fluent, logger: Logger(label: "t")),
                eventBus: EventBus(logger: Logger(label: "t")),
                proactiveChat: ProactiveChatDelivery(fluent: h.fluent, apns: apns, logger: Logger(label: "t")),
                logger: Logger(label: "t")
            )
            let manifest = SkillManifest(
                source: .vault, name: "job-dry-week", description: "Dry week watch",
                allowedTools: ["weather_forecast"], capability: .low, schedule: "0 8 * * *", onEvent: [],
                outputs: [.init(kind: .chatMessage, path: nil, category: nil)],
                dailyRunCap: nil, body: "Check the weather."
            )
            let result = try await runner.run(skill: manifest, tenantID: h.tenantID, profileUsername: h.username, trigger: .cron)
            #expect(result.status == "ok")

            let thread = try #require(try await Conversation.query(on: h.fluent.db(), tenantID: h.tenantID)
                .filter(\.$systemKey == "hermie").first())
            let messages = try await ConversationMessage.query(on: h.fluent.db())
                .filter(\.$conversationID == thread.requireID()).all()
            #expect(messages.count == 1)
            #expect(messages.first?.origin == "proactive")
            #expect(messages.first?.sourceLabel == "job-dry-week")
            #expect(messages.first?.content.hasPrefix("Five dry days") == true)
            #expect(await push.sends.map(\.category) == [.chat])
        }
    }

    // MARK: - Kept location

    @Test
    func `the location fix is kept, read back, and forgotten when Location is revoked`() async throws {
        try await Self.withHarness { h in
            let sql = try #require(h.fluent.db() as? any SQLDatabase)
            let store = LastKnownLocationStore(sql: sql)
            #expect(try await store.load(tenantID: h.tenantID) == nil)

            let at = Date(timeIntervalSince1970: 1_790_000_000)
            try await store.save(tenantID: h.tenantID, fix: LocationFix(latitude: 38.72, longitude: -9.14, place: "Lisbon", capturedAt: at))
            let loaded = try #require(try await store.load(tenantID: h.tenantID))
            #expect(loaded.latitude == 38.72)
            #expect(loaded.place == "Lisbon")
            #expect(abs(loaded.capturedAt.timeIntervalSince(at)) < 1)

            try await AppleConsentController.purgeDomain(tenantID: h.tenantID, domain: .location, sql: sql)
            #expect(try await store.load(tenantID: h.tenantID) == nil)
        }
    }

    // MARK: - Gmail on the shared Google grant

    private static func oauthService(_ h: Harness) throws -> GoogleCalendarOAuthService {
        let logger = Logger(label: "test.gmail")
        let key = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }).base64EncodedString()
        let secretBox = try SecretBox(masterKeyBase64: key)
        // Never used for network here: the scenarios below have no tokens to
        // refresh or revoke.
        let oauth = GoogleCalendarOAuthClient(clientID: "id", clientSecret: "not-a-secret", redirectURI: "https://x/cb", logger: logger)
        let tokens = CalendarTokenStore(fluent: h.fluent, secretBox: secretBox, oauth: oauth, logger: logger)
        return GoogleCalendarOAuthService(
            fluent: h.fluent,
            oauth: oauth,
            tokenStore: tokens,
            syncService: CalendarSyncService(fluent: h.fluent, tokenStore: tokens, client: GoogleCalendarClient(logger: logger), logger: logger),
            sessionStore: CalendarOAuthSessionStore(),
            isConfigured: true,
            logger: logger
        )
    }

    static let both = "openid https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/gmail.readonly email"

    @Test
    func `Gmail and Calendar each report their own half of the grant`() async throws {
        try await Self.withHarness { h in
            let service = try Self.oauthService(h)
            #expect(try await service.gmailStatus(tenantID: h.tenantID) == .init(connected: false, needsReauth: false, accountEmail: nil, calendarConnected: false))

            // Calendar only.
            let account = CalendarAccount(tenantID: h.tenantID, accountEmail: "me@example.com", scope: GoogleCalendarOAuthClient.scope)
            try await account.save(on: h.fluent.db())
            #expect(try await service.gmailStatus(tenantID: h.tenantID).connected == false)
            #expect(try await service.gmailStatus(tenantID: h.tenantID).calendarConnected == true)

            // Gmail only: Calendar must not claim to be connected.
            account.scope = GoogleCalendarOAuthClient.gmailConnectScope
            try await account.save(on: h.fluent.db())
            #expect(try await service.gmailStatus(tenantID: h.tenantID) == .init(connected: true, needsReauth: false, accountEmail: "me@example.com", calendarConnected: false))
            #expect(try await service.status(tenantID: h.tenantID).connected == false)
        }
    }

    @Test
    func `disconnecting Gmail keeps Calendar when both share the grant`() async throws {
        try await Self.withHarness { h in
            let service = try Self.oauthService(h)
            try await CalendarAccount(tenantID: h.tenantID, accountEmail: "me@example.com", scope: Self.both).save(on: h.fluent.db())

            try await service.disconnectGmail(tenantID: h.tenantID)

            #expect(try await service.gmailStatus(tenantID: h.tenantID).connected == false)
            #expect(try await service.status(tenantID: h.tenantID).connected == true)
        }
    }

    @Test
    func `disconnecting Calendar keeps Gmail, and Gmail alone deletes the grant`() async throws {
        try await Self.withHarness { h in
            let service = try Self.oauthService(h)
            try await CalendarAccount(tenantID: h.tenantID, accountEmail: "me@example.com", scope: Self.both).save(on: h.fluent.db())

            try await service.disconnect(tenantID: h.tenantID)
            #expect(try await service.status(tenantID: h.tenantID).connected == false)
            #expect(try await service.gmailStatus(tenantID: h.tenantID).connected == true)

            try await service.disconnectGmail(tenantID: h.tenantID)
            let rows = try await CalendarAccount.query(on: h.fluent.db(), tenantID: h.tenantID).all()
            #expect(rows.isEmpty)
        }
    }

    @Test
    func `Connect Gmail remembers its purpose for the shared callback`() async throws {
        try await Self.withHarness { h in
            let service = try Self.oauthService(h)
            let url = try await service.start(tenantID: h.tenantID, purpose: .gmail)
            #expect(url.contains("gmail.readonly"))
            #expect(url.contains("include_granted_scopes=true"))
            // Declining lands the iOS app on the Gmail deep link, not Calendar's.
            let state = try #require(URLComponents(string: url)?.queryItems?.first { $0.name == "state" }?.value)
            let redirect = await service.handleCallback(state: state, code: nil, error: "access_denied")
            #expect(redirect == "luminavault://oauth/google-gmail?status=error&reason=access_denied")
        }
    }
}

/// Answers every completion with one fixed assistant message.
private struct FixedReplyTransport: HermesChatTransport {
    let content: String

    func chatCompletions(payload _: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
        let body: [String: Any] = [
            "id": "chatcmpl-test",
            "model": "test-model",
            "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }
}
