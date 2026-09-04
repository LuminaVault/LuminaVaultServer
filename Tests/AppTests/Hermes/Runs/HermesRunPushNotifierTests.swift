@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// The APNS side of a run: the `approval` category is what makes the lock
/// screen actionable, and both new categories must honour the per-tenant
/// opt-out table (M119).
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct HermesRunPushNotifierTests {
    private struct Harness: Sendable {
        let tenantID: UUID
        let sender: RecordingPushSender
        let notifier: APNSHermesRunPushNotifier
        let fluent: Fluent
    }

    private static func withHarness(_ body: (Harness) async throws -> Void) async throws {
        try await withTestFluent(label: "test.hermes.runs.push") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let user = User(
                email: "push-\(suffix)@test.luminavault",
                username: "push-\(suffix)",
                passwordHash: "stub"
            )
            try await user.save(on: fluent.db())
            let tenantID = try user.requireID()
            try await DeviceToken(tenantID: tenantID, token: UUID().uuidString, platform: "ios")
                .save(on: fluent.db())

            let sender = RecordingPushSender()
            let notifier = APNSHermesRunPushNotifier(
                push: APNSNotificationService(
                    bundleID: "com.lumina.test",
                    fluent: fluent,
                    pushSender: sender,
                    logger: Logger(label: "test.apns")
                ),
                logger: Logger(label: "test.hermes.runs.push")
            )
            try await body(Harness(tenantID: tenantID, sender: sender, notifier: notifier, fluent: fluent))
        }
    }

    private static func run(
        status: HermesRunStatus,
        pendingApproval: HermesRunPendingApprovalDTO? = nil,
        summary: String? = nil,
        error: String? = nil
    ) -> HermesRunDTO {
        HermesRunDTO(
            id: UUID(),
            hermesRunID: "run_push",
            status: status,
            prompt: "clean the temp dir",
            startedAt: Date(),
            lastSeq: 1,
            pendingApproval: pendingApproval,
            summary: summary,
            error: error
        )
    }

    @Test
    func `an approval request pushes the actionable approval category`() async throws {
        try await Self.withHarness { harness in
            let run = Self.run(
                status: .waitingForApproval,
                pendingApproval: HermesRunPendingApprovalDTO(
                    command: "rm -rf /tmp/build",
                    choices: [.once, .deny],
                    requestedAt: Date()
                )
            )
            await harness.notifier.approvalRequested(tenantID: harness.tenantID, run: run)

            let sends = await harness.sender.sends
            #expect(sends.count == 1)
            let send = try #require(sends.first)
            #expect(send.category == .approval)
            #expect(send.title == APNSHermesRunPushNotifier.approvalTitle)
            #expect(send.body == "rm -rf /tmp/build")
            #expect(send.payload["runID"] == run.id.uuidString)
            #expect(send.payload["hermesRunID"] == "run_push")
            // The client needs the offered answers to build the action buttons.
            #expect(send.payload["choices"] == "once,deny")
        }
    }

    @Test
    func `a finished run pushes the runCompleted category with its outcome`() async throws {
        try await Self.withHarness { harness in
            await harness.notifier.runFinished(
                tenantID: harness.tenantID,
                run: Self.run(status: .completed, summary: "removed 12 files")
            )
            await harness.notifier.runFinished(
                tenantID: harness.tenantID,
                run: Self.run(status: .failed, error: "shell exited 1")
            )

            let sends = await harness.sender.sends
            #expect(sends.count == 2)
            #expect(sends.allSatisfy { $0.category == .runCompleted })
            #expect(sends[0].body == "removed 12 files")
            #expect(sends[0].title == "Hermes finished a run")
            #expect(sends[1].body == "shell exited 1")
            #expect(sends[1].title == "Hermes run failed")
        }
    }

    @Test
    func `each new category is independently mutable through the prefs table`() async throws {
        try await Self.withHarness { harness in
            try await ApnsCategoryPrefs(
                tenantID: harness.tenantID,
                approvalEnabled: false,
                runCompletedEnabled: true
            ).save(on: harness.fluent.db())

            await harness.notifier.approvalRequested(
                tenantID: harness.tenantID,
                run: Self.run(status: .waitingForApproval)
            )
            await harness.notifier.runFinished(
                tenantID: harness.tenantID,
                run: Self.run(status: .completed, summary: "done")
            )

            let sends = await harness.sender.sends
            #expect(sends.map(\.category) == [.runCompleted])
        }
    }

    @Test
    func `an approval with no command still says something useful`() async throws {
        try await Self.withHarness { harness in
            await harness.notifier.approvalRequested(
                tenantID: harness.tenantID,
                run: Self.run(status: .waitingForApproval)
            )
            let send = try #require(await harness.sender.sends.first)
            #expect(send.body == "A tool call is waiting for your approval")
            // No pending approval means no narrowed choices — offer them all.
            #expect(send.payload["choices"] == "once,session,always,deny")
        }
    }
}
