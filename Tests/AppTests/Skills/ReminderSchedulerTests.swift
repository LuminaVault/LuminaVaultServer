@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// Drives `ReminderScheduler.tick` against a stub `APNSPushSender`. Verifies
/// one-shot fire + `firedAt` stamp, recurring advance, and that an
/// already-fired reminder is left alone. Reuses `RecordingPushSender` from
/// `APNSNotificationServiceTests`.
@Suite(.serialized)
struct ReminderSchedulerTests {
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
        let fluent = Fluent(logger: Logger(label: "test.reminders"))
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
        await fluent.migrations.add(M63_CreateReminder())
        do {
            try await fluent.migrate()
            return fluent
        } catch {
            try? await fluent.shutdown()
            throw error
        }
    }

    private static func makeUser(_ slug: String, on db: any Database) async throws -> User {
        let user = User(email: "\(slug)@test.luminavault", username: slug, passwordHash: "stub-\(slug)")
        try await user.save(on: db)
        return user
    }

    private static func makeService(_ fluent: Fluent, _ recorder: RecordingPushSender) -> APNSNotificationService {
        APNSNotificationService(
            bundleID: "com.luminavault.test",
            fluent: fluent,
            pushSender: recorder,
            logger: Logger(label: "test.reminders"),
        )
    }

    @Test
    func `due one-shot reminder fires and is stamped`() async throws {
        try await Self.withFluent { fluent in
            let slug = "rem1\(UUID().uuidString.prefix(6).lowercased())"
            let user = try await Self.makeUser(slug, on: fluent.db())
            let userID = try user.requireID()
            try await DeviceToken(tenantID: userID, token: UUID().uuidString, platform: "ios").save(on: fluent.db())

            let reminder = Reminder(
                tenantID: userID,
                title: "Drink water",
                body: "Stay hydrated",
                fireAt: Date().addingTimeInterval(-120),
            )
            try await reminder.save(on: fluent.db())

            let recorder = RecordingPushSender()
            let scheduler = ReminderScheduler(fluent: fluent, push: Self.makeService(fluent, recorder), logger: Logger(label: "test.reminders"))
            let fired = try await scheduler.tick(at: Date())

            #expect(fired == 1)
            let sends = await recorder.sends
            #expect(sends.count == 1)
            #expect(sends.first?.category == .reminder)
            #expect(sends.first?.title == "Drink water")

            let reloaded = try await Reminder.find(reminder.requireID(), on: fluent.db())
            #expect(reloaded?.firedAt != nil)
        }
    }

    @Test
    func `recurring reminder advances fireAt and stays armed`() async throws {
        try await Self.withFluent { fluent in
            let slug = "rem2\(UUID().uuidString.prefix(6).lowercased())"
            let user = try await Self.makeUser(slug, on: fluent.db())
            let userID = try user.requireID()
            try await DeviceToken(tenantID: userID, token: UUID().uuidString, platform: "ios").save(on: fluent.db())

            let reminder = Reminder(
                tenantID: userID,
                title: "Daily standup",
                body: "9am",
                fireAt: Date().addingTimeInterval(-120),
                recurrenceCron: "* * * * *", // every minute → next match is imminent
            )
            try await reminder.save(on: fluent.db())

            let recorder = RecordingPushSender()
            let scheduler = ReminderScheduler(fluent: fluent, push: Self.makeService(fluent, recorder), logger: Logger(label: "test.reminders"))
            let now = Date()
            _ = try await scheduler.tick(at: now)

            let reloaded = try await Reminder.find(reminder.requireID(), on: fluent.db())
            #expect(reloaded?.firedAt == nil)            // re-armed, not stamped
            #expect((reloaded?.fireAt ?? now) > now)     // advanced into the future
        }
    }

    @Test
    func `already-fired and future reminders are skipped`() async throws {
        try await Self.withFluent { fluent in
            let slug = "rem3\(UUID().uuidString.prefix(6).lowercased())"
            let user = try await Self.makeUser(slug, on: fluent.db())
            let userID = try user.requireID()

            // Already fired (firedAt set) — must not re-fire.
            let fired = Reminder(tenantID: userID, title: "old", body: "x", fireAt: Date().addingTimeInterval(-300), firedAt: Date().addingTimeInterval(-240))
            try await fired.save(on: fluent.db())
            // Future — not due yet.
            let future = Reminder(tenantID: userID, title: "later", body: "y", fireAt: Date().addingTimeInterval(3600))
            try await future.save(on: fluent.db())

            let recorder = RecordingPushSender()
            let scheduler = ReminderScheduler(fluent: fluent, push: Self.makeService(fluent, recorder), logger: Logger(label: "test.reminders"))
            let count = try await scheduler.tick(at: Date())

            #expect(count == 0)
            let sends = await recorder.sends
            #expect(sends.isEmpty)
        }
    }
}
