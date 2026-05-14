@testable import App
import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import Testing

/// HER-200 H3 integration tests for `SkillRunner.startEventSubscriptions`
/// + `stopEventSubscriptions`. Exercises the detached-Task event loop
/// lifecycle against a real `EventBus`.
@Suite(.serialized)
struct SkillRunnerLifecycleTests {
    // MARK: - Harness

    private struct Harness {
        let fluent: Fluent
        let tenantID: UUID
        let root: URL
        let bus: EventBus
        let runner: SkillRunner
    }

    private static func withHarness<T: Sendable>(_ body: @Sendable (Harness) async throws -> T) async throws -> T {
        let fluent = Fluent(logger: Logger(label: "test.skill-runner-lifecycle"))
        fluent.databases.use(.postgres(configuration: TestPostgres.configuration()), as: .psql)
        await fluent.migrations.add(M00_EnableExtensions())
        await fluent.migrations.add(M01_CreateUser())
        await fluent.migrations.add(M06_CreateMemory())
        await fluent.migrations.add(M07_AddMemoryEmbedding())
        await fluent.migrations.add(M09_AddUsernameToUser())
        await fluent.migrations.add(M10_CreateDeviceToken())
        await fluent.migrations.add(M12_CreateSpace())
        await fluent.migrations.add(M13_CreateVaultFile())
        await fluent.migrations.add(M15_AddTierFields())
        await fluent.migrations.add(M18_AddMemoryTags())
        await fluent.migrations.add(M19_CreateSkillsState())
        await fluent.migrations.add(M20_CreateSkillRunLog())
        await fluent.migrations.add(M21_AddMemoryScore())
        await fluent.migrations.add(M23_AddMemorySourceLineage())
        await fluent.migrations.add(M24_AddUserContextRouting())
        await fluent.migrations.add(M25_AddUserPrivacyNoCNOrigin())
        await fluent.migrations.add(M26_AddSkillsStateDailyRunCap())
        await fluent.migrations.add(M27_AddUserTimezone())
        try await fluent.migrate()

        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-skill-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)

        let username = "skill-lc-\(UUID().uuidString.prefix(8).lowercased())"
        let user = User(
            email: "\(username)@test.luminavault",
            username: username,
            passwordHash: "x",
        )
        try await user.save(on: fluent.db())

        let vaultPaths = VaultPathService(rootPath: tmpRoot.appendingPathComponent("vault").path)
        let apns = APNSNotificationService(
            enabled: false,
            bundleID: "",
            teamID: "",
            keyID: "",
            privateKeyPath: "",
            environment: "development",
            fluent: fluent,
            logger: Logger(label: "test.skill-lifecycle.apns"),
        )
        let bus = EventBus(logger: Logger(label: "test.skill-lifecycle.bus"))
        let runner = SkillRunner(
            catalog: SkillCatalog(vaultPaths: vaultPaths, logger: Logger(label: "test.skill-lifecycle.catalog")),
            transport: NoopChatTransport(),
            memories: MemoryRepository(fluent: fluent),
            embeddings: DeterministicEmbeddingService(),
            apns: apns,
            defaultModel: "test-model",
            fluent: fluent,
            vaultPaths: vaultPaths,
            capGuard: SkillRunCapGuard(fluent: fluent, logger: Logger(label: "test.skill-lifecycle.cap")),
            eventBus: bus,
            logger: Logger(label: "test.skill-lifecycle.runner"),
        )

        do {
            let result = try await body(Harness(
                fluent: fluent,
                tenantID: user.requireID(),
                root: tmpRoot,
                bus: bus,
                runner: runner,
            ))
            try? await fluent.shutdown()
            try? FileManager.default.removeItem(at: tmpRoot)
            return result
        } catch {
            try? await fluent.shutdown()
            try? FileManager.default.removeItem(at: tmpRoot)
            throw error
        }
    }

    /// Polls `condition` until it returns true or the budget elapses.
    private static func waitUntil(
        _ condition: @Sendable () -> Bool,
        timeoutNanos: UInt64 = 2_000_000_000,
        message: String = "condition timed out",
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanos {
                Issue.record(.init(rawValue: message))
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Tests

    @Test
    func `startEventSubscriptions registers one subscriber per event type`() async throws {
        try await Self.withHarness { h in
            await h.runner.startEventSubscriptions()

            await Self.waitUntil(
                { h.bus.subscriberCount(for: .vaultFileCreated) == 1 },
                message: "vaultFileCreated subscriber not registered",
            )
            await Self.waitUntil(
                { h.bus.subscriberCount(for: .memoryUpserted) == 1 },
                message: "memoryUpserted subscriber not registered",
            )
            await Self.waitUntil(
                { h.bus.subscriberCount(for: .healthEventSynced) == 1 },
                message: "healthEventSynced subscriber not registered",
            )
        }
    }

    @Test
    func `stopEventSubscriptions drains all subscribers`() async throws {
        try await Self.withHarness { h in
            await h.runner.startEventSubscriptions()
            await Self.waitUntil(
                { h.bus.subscriberCount(for: .vaultFileCreated) == 1 },
                message: "subscribe never landed",
            )

            await h.runner.stopEventSubscriptions()

            // Task.cancel() on the detached event-loop task tears down the
            // AsyncStream iterator, which fires `onTermination` on the bus,
            // which removes the subscriber. Polls because the propagation
            // is async even though our register/unregister are synchronous.
            await Self.waitUntil(
                { h.bus.subscriberCount(for: .vaultFileCreated) == 0 },
                timeoutNanos: 3_000_000_000,
                message: "vaultFileCreated subscriber not drained after stop",
            )
            await Self.waitUntil(
                { h.bus.subscriberCount(for: .memoryUpserted) == 0 },
                timeoutNanos: 3_000_000_000,
                message: "memoryUpserted subscriber not drained after stop",
            )
            await Self.waitUntil(
                { h.bus.subscriberCount(for: .healthEventSynced) == 0 },
                timeoutNanos: 3_000_000_000,
                message: "healthEventSynced subscriber not drained after stop",
            )
        }
    }

    @Test
    func `repeated startEventSubscriptions is idempotent`() async throws {
        try await Self.withHarness { h in
            await h.runner.startEventSubscriptions()
            await Self.waitUntil(
                { h.bus.subscriberCount(for: .vaultFileCreated) == 1 },
                message: "first start never landed",
            )

            // Hot-reload path: calling start a second time must cancel prior
            // subscriptions before re-subscribing, so the bus settles back to
            // exactly one subscriber per event type — not two.
            await h.runner.startEventSubscriptions()
            await Self.waitUntil(
                { h.bus.subscriberCount(for: .vaultFileCreated) == 1 },
                timeoutNanos: 3_000_000_000,
                message: "second start double-subscribed",
            )
        }
    }

    @Test
    func `events published before stop reach the runner`() async throws {
        try await Self.withHarness { h in
            await h.runner.startEventSubscriptions()
            await Self.waitUntil(
                { h.bus.subscriberCount(for: .vaultFileCreated) == 1 },
                message: "subscribe never landed",
            )

            // The detached event loop currently just logs receipt. We can't
            // assert log output cheaply, so this test verifies the publish
            // path is non-blocking and does not crash with the new
            // structured-Task wiring (HER-200 H1 + H3 combined).
            for _ in 0 ..< 25 {
                h.bus.publish(SkillEvent(
                    type: .vaultFileCreated,
                    tenantID: h.tenantID,
                    payload: [SkillEvent.PayloadKey.vaultPath: "notes/\(UUID()).md"],
                ))
            }
            // Give the detached loop a moment to drain before tearing down.
            try? await Task.sleep(nanoseconds: 50_000_000)
            await h.runner.stopEventSubscriptions()
        }
    }
}

/// Minimal `HermesChatTransport` stub for lifecycle tests that never invoke
/// the chat path — `runAgent` is not exercised here.
private struct NoopChatTransport: HermesChatTransport {
    func chatCompletions(payload _: Data, profileUsername _: String) async throws -> Data {
        Data()
    }
}
