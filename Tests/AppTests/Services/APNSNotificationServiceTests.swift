import APNSCore
@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import Testing

/// Drives `APNSNotificationService` through the new `APNSPushSender` test
/// seam. Verifies fan-out to multiple device tokens, dead-token reaping,
/// no-op when service disabled, and category routing.
@Suite(.serialized)
struct APNSNotificationServiceTests {
    // MARK: - Fixtures

    private static func withFluent<T: Sendable>(
        _ body: @Sendable (Fluent) async throws -> T,
    ) async throws -> T {
        let fluent = try await makeFluent()
        do {
            let result = try await body(fluent)
            try await fluent.shutdown()
            return result
        } catch {
            try? await fluent.shutdown()
            throw error
        }
    }

    private static func makeFluent() async throws -> Fluent {
        let fluent = Fluent(logger: Logger(label: "test.apns"))
        fluent.databases.use(
            .postgres(configuration: TestPostgres.configuration()),
            as: .psql,
        )
        await fluent.migrations.add(M00_EnableExtensions())
        await fluent.migrations.add(M01_CreateUser())
        await fluent.migrations.add(M02_CreateRefreshToken())
        await fluent.migrations.add(M03_CreatePasswordResetToken())
        await fluent.migrations.add(M04_CreateMFAChallenge())
        await fluent.migrations.add(M05_CreateOAuthIdentity())
        await fluent.migrations.add(M06_CreateMemory())
        await fluent.migrations.add(M07_AddMemoryEmbedding())
        await fluent.migrations.add(M08_CreateHermesProfile())
        await fluent.migrations.add(M09_AddUsernameToUser())
        await fluent.migrations.add(M10_CreateDeviceToken())
        await fluent.migrations.add(M11_CreateWebAuthnCredential())
        await fluent.migrations.add(M12_CreateSpace())
        await fluent.migrations.add(M13_CreateVaultFile())
        await fluent.migrations.add(M14_CreateHealthEvent())
        await fluent.migrations.add(M15_AddTierFields())
        try await fluent.migrate()
        return fluent
    }

    private static func makeUser(_ slug: String, on db: any Database) async throws -> User {
        let user = User(
            email: "\(slug)@test.luminavault",
            username: slug,
            passwordHash: "stub-\(slug)",
        )
        try await user.save(on: db)
        return user
    }

    // MARK: - Tests

    @Test
    func `notify LLM reply fans out to every registered token`() async throws {
        try await Self.withFluent { fluent in
            let slug = "apns1\(UUID().uuidString.prefix(6).lowercased())"
            let user = try await Self.makeUser(slug, on: fluent.db())
            let userID = try user.requireID()

            try await DeviceToken(tenantID: userID, token: UUID().uuidString, platform: "ios").save(on: fluent.db())
            try await DeviceToken(tenantID: userID, token: UUID().uuidString, platform: "ios").save(on: fluent.db())
            try await DeviceToken(tenantID: userID, token: UUID().uuidString, platform: "android").save(on: fluent.db())

            let recorder = RecordingPushSender()
            let service = APNSNotificationService(
                bundleID: "com.luminavault.test",
                fluent: fluent,
                pushSender: recorder,
                logger: Logger(label: "test.apns"),
            )
            let response = ChatResponse(
                id: "test", model: "test",
                message: ChatMessage(role: "assistant", content: "Hello there"),
                raw: HermesUpstreamResponse(id: "test", object: nil, created: nil, model: "test", choices: [], usage: nil),
            )
            try await service.notifyLLMReply(userID: userID, username: slug, response: response)

            let sends = await recorder.sends
            #expect(sends.count == 3)
            #expect(sends.allSatisfy { $0.topic == "com.luminavault.test" })
            #expect(sends.allSatisfy { $0.category == .chat })
        }
    }

    @Test
    func `dead tokens are reaped on bad device token error`() async throws {
        try await Self.withFluent { fluent in
            let slug = "apns2\(UUID().uuidString.prefix(6).lowercased())"
            let user = try await Self.makeUser(slug, on: fluent.db())
            let userID = try user.requireID()

            let aliveToken = UUID().uuidString
            let deadToken = UUID().uuidString
            try await DeviceToken(tenantID: userID, token: aliveToken, platform: "ios").save(on: fluent.db())
            try await DeviceToken(tenantID: userID, token: deadToken, platform: "ios").save(on: fluent.db())

            let recorder = RecordingPushSender()
            await recorder.failOn(token: deadToken, with: "BadDeviceToken")

            let service = APNSNotificationService(
                bundleID: "com.luminavault.test",
                fluent: fluent,
                pushSender: recorder,
                logger: Logger(label: "test.apns"),
            )
            try await service.notifyNudge(userID: userID, username: slug, body: "test nudge")

            let remaining = try await DeviceToken
                .query(on: fluent.db(), tenantID: userID)
                .all()
            let remainingTokens = Set(remaining.map(\.token))
            #expect(remainingTokens.contains(aliveToken))
            #expect(!remainingTokens.contains(deadToken))
        }
    }

    @Test
    func `transient errors do not reap the token`() async throws {
        try await Self.withFluent { fluent in
            let slug = "apns3\(UUID().uuidString.prefix(6).lowercased())"
            let user = try await Self.makeUser(slug, on: fluent.db())
            let userID = try user.requireID()
            let token = UUID().uuidString
            try await DeviceToken(tenantID: userID, token: token, platform: "ios").save(on: fluent.db())

            let recorder = RecordingPushSender()
            await recorder.failOn(token: token, with: "InternalServerError")

            let service = APNSNotificationService(
                bundleID: "com.luminavault.test",
                fluent: fluent,
                pushSender: recorder,
                logger: Logger(label: "test.apns"),
            )
            try await service.notifyDigest(userID: userID, username: slug, body: "today")

            let remaining = try await DeviceToken
                .query(on: fluent.db(), tenantID: userID)
                .all()
            #expect(remaining.contains { $0.token == token })
        }
    }

    @Test
    func `disabled service is no op`() async throws {
        try await Self.withFluent { fluent in
            let slug = "apns4\(UUID().uuidString.prefix(6).lowercased())"
            let user = try await Self.makeUser(slug, on: fluent.db())
            let userID = try user.requireID()
            try await DeviceToken(tenantID: userID, token: UUID().uuidString, platform: "ios").save(on: fluent.db())

            // Production-style constructor with `enabled=false` → pushSender stays nil.
            let service = APNSNotificationService(
                enabled: false,
                bundleID: "",
                teamID: "",
                keyID: "",
                privateKeyPath: "",
                environment: "development",
                fluent: fluent,
                logger: Logger(label: "test.apns"),
            )
            try await service.notifyLLMReply(
                userID: userID,
                username: slug,
                response: ChatResponse(
                    id: "test", model: "test",
                    message: ChatMessage(role: "assistant", content: "x"),
                    raw: HermesUpstreamResponse(id: "test", object: nil, created: nil, model: "test", choices: [], usage: nil),
                ),
            )
            // No throw, no crash. Token row untouched.
            let remaining = try await DeviceToken.query(on: fluent.db(), tenantID: userID).all()
            #expect(remaining.count == 1)
        }
    }

    @Test
    func `should reap classifies every dead reason`() throws {
        for raw in APNSNotificationService.deadTokenReasons {
            let err = try Self.makeAPNSError(reason: raw)
            #expect(APNSNotificationService.shouldReap(err))
        }
        let transient = try Self.makeAPNSError(reason: "InternalServerError")
        #expect(!APNSNotificationService.shouldReap(transient))
        struct OtherError: Error {}
        #expect(!APNSNotificationService.shouldReap(OtherError()))
    }

    /// `APNSErrorResponse`'s memberwise init is internal (Codable shadow).
    /// Round-trip through JSON to build one in tests.
    static func makeAPNSError(reason: String) throws -> APNSError {
        let json = "{\"reason\":\"\(reason)\"}".data(using: .utf8)!
        let resp = try JSONDecoder().decode(APNSErrorResponse.self, from: json)
        return APNSError(responseStatus: 410, apnsResponse: resp)
    }
}

// MARK: - Stub push sender

actor RecordingPushSender: APNSPushSender {
    struct Send {
        let token: String
        let title: String
        let subtitle: String?
        let body: String
        let category: APNSPushCategory
        let topic: String
    }

    private(set) var sends: [Send] = []
    private var failures: [String: String] = [:] // token -> APNS reason string

    func failOn(token: String, with reason: String) {
        failures[token] = reason
    }

    nonisolated func send(
        deviceToken: String,
        title: String,
        subtitle: String?,
        body: String,
        category: APNSPushCategory,
        topic: String,
    ) async throws {
        try await record(
            deviceToken: deviceToken,
            title: title,
            subtitle: subtitle,
            body: body,
            category: category,
            topic: topic,
        )
    }

    private func record(
        deviceToken: String,
        title: String,
        subtitle: String?,
        body: String,
        category: APNSPushCategory,
        topic: String,
    ) throws {
        sends.append(Send(
            token: deviceToken,
            title: title,
            subtitle: subtitle,
            body: body,
            category: category,
            topic: topic,
        ))
        if let reason = failures[deviceToken] {
            throw try APNSNotificationServiceTests.makeAPNSError(reason: reason)
        }
    }
}
