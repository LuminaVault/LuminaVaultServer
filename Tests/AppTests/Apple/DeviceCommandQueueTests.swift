@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// Phone writes queued while the app was closed.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct DeviceCommandQueueTests {
    private static func queue(_ fluent: Fluent) -> DeviceCommandQueue {
        // No APNs: the push is best-effort and must not affect queueing.
        DeviceCommandQueue(fluent: fluent, apns: nil, logger: Logger(label: "test.device-queue"))
    }

    @Test
    func `a queued write is pending for its owner only, until its result arrives`() async throws {
        try await withTestFluent(label: "lv.test.device-queue") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let queue = Self.queue(fluent)
            let alice = UUID()
            let bob = UUID()
            let command = DeviceCommand(kind: .reminderCreate, domain: .reminders, payload: ["title": "Call mom", "due": ""])

            try await queue.enqueue(tenantID: alice, command: command)

            let pending = try await queue.pending(tenantID: alice)
            #expect(pending.map(\.id) == [command.id])
            #expect(pending.first?.kind == .reminderCreate)
            #expect(pending.first?.domain == .reminders)
            #expect(pending.first?.payload["title"] == "Call mom")
            #expect(try await queue.pending(tenantID: bob).isEmpty)

            // Bob posting a result for Alice's command id changes nothing.
            try await queue.markDelivered(tenantID: bob, result: DeviceCommandResult(id: command.id, ok: true))
            #expect(try await queue.pending(tenantID: alice).map(\.id) == [command.id])

            try await queue.markDelivered(tenantID: alice, result: DeviceCommandResult(id: command.id, ok: false, error: "denied"))
            #expect(try await queue.pending(tenantID: alice).isEmpty)
            let row = try #require(try await QueuedDeviceCommand.find(command.id, on: fluent.db()))
            #expect(row.resultOK == false)
            #expect(row.resultError == "denied")
        }
    }

    @Test
    func `an expired write is never handed to the phone`() async throws {
        try await withTestFluent(label: "lv.test.device-queue.expiry") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let queue = Self.queue(fluent)
            let tenant = UUID()
            let command = DeviceCommand(kind: .calendarCreate, domain: .calendar, payload: ["title": "Dentist"])
            try await queue.enqueue(tenantID: tenant, command: command)

            let row = try #require(try await QueuedDeviceCommand.find(command.id, on: fluent.db()))
            row.expiresAt = Date().addingTimeInterval(-60)
            try await row.save(on: fluent.db())

            #expect(try await queue.pending(tenantID: tenant).isEmpty)
        }
    }

    @Test
    func `only writes queue, and the push says what is waiting`() {
        #expect(DeviceCommandQueue.queueable == [.reminderCreate, .calendarCreate])
        #expect(!DeviceCommandQueue.queueable.contains(.deviceFetch))
        #expect(DeviceCommandQueue.announcement(for: DeviceCommand(kind: .reminderCreate, payload: ["title": "Call mom"]))
            == "Open LuminaVault to add the reminder “Call mom”.")
        #expect(DeviceCommandQueue.announcement(for: DeviceCommand(kind: .calendarCreate, payload: [:]))
            == "Open LuminaVault to add “an item” to your calendar.")
    }
}
