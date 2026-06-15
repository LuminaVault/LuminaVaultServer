import APNSCore
@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// Covers the HER-Cron push surface: `notifyCron` fans out with the `.cron`
/// category and the skill name as subtitle. Reuses `RecordingPushSender`
/// from `APNSNotificationServiceTests`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct CronPushTests {
    private static func withFluent<T: Sendable>(
        _ body: @Sendable (Fluent) async throws -> T
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
        let fluent = Fluent(logger: Logger(label: "test.cronpush"))
        fluent.databases.use(.postgres(configuration: TestPostgres.configuration()), as: .psql)
        await fluent.migrations.add(M00_EnableExtensions())
        await fluent.migrations.add(M01_CreateUser())
        await fluent.migrations.add(M10_CreateDeviceToken())
        do {
            try await fluent.migrate()
            return fluent
        } catch {
            try? await fluent.shutdown()
            throw error
        }
    }

    @Test
    func `notifyCron delivers with cron category and skill subtitle`() async throws {
        try await Self.withFluent { fluent in
            let slug = "cron\(UUID().uuidString.prefix(6).lowercased())"
            let user = User(email: "\(slug)@test.luminavault", username: slug, passwordHash: "stub")
            try await user.save(on: fluent.db())
            let userID = try user.requireID()
            try await DeviceToken(tenantID: userID, token: UUID().uuidString, platform: "ios").save(on: fluent.db())

            let recorder = RecordingPushSender()
            let service = APNSNotificationService(
                bundleID: "com.luminavault.test",
                fluent: fluent,
                pushSender: recorder,
                logger: Logger(label: "test.cronpush")
            )
            try await service.notifyCron(userID: userID, skillName: "pattern-detector", body: "ran")

            let sends = await recorder.sends
            #expect(sends.count == 1)
            #expect(sends.first?.category == .cron)
            #expect(sends.first?.subtitle == "pattern-detector")
        }
    }
}
