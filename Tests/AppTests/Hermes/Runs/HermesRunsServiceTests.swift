@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// End-to-end behaviour of the runs service against Postgres and a fake
/// gateway: the watcher persisting a live stream, the approval round-trip,
/// stop, boot re-attach, and the TTL past which a run is `lost`.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct HermesRunsServiceTests {
    // MARK: - Harness

    struct Harness: Sendable {
        let fluent: Fluent
        let gateway: FakeHermesRunsGateway
        let notifier: RecordingRunPushNotifier
        let eventBus: EventBus
        let service: HermesRunsService
        let tenantID: UUID
        let hermesRunID: String
    }

    private static func withHarness(
        hermesRunID: String = "run_1",
        limits: HermesRunsService.Limits = HermesRunsService.Limits(),
        now: @escaping @Sendable () -> Date = Date.init,
        _ body: (Harness) async throws -> Void
    ) async throws {
        try await withTestFluent(label: "test.hermes.runs.service") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let user = User(
                email: "runs-\(suffix)@test.luminavault",
                username: "runs-\(suffix)",
                passwordHash: "stub"
            )
            try await user.save(on: fluent.db())
            let tenantID = try user.requireID()

            let gateway = FakeHermesRunsGateway.accepting(runID: hermesRunID)
            let notifier = RecordingRunPushNotifier()
            let eventBus = EventBus(logger: Logger(label: "test.eventbus"))
            let logger = Logger(label: "test.hermes.runs.service")
            let service = HermesRunsService(
                fluent: fluent,
                eventBus: eventBus,
                notifier: notifier,
                resolve: { _ in
                    .init(baseURL: URL(string: "http://hermes.test")!, authHeader: nil, isUserOverride: false)
                },
                makeClient: { _, sessionKey in gateway.client(sessionKey: sessionKey) },
                limits: limits,
                logger: logger,
                now: now
            )
            let harness = Harness(
                fluent: fluent,
                gateway: gateway,
                notifier: notifier,
                eventBus: eventBus,
                service: service,
                tenantID: tenantID,
                hermesRunID: hermesRunID
            )
            do {
                try await body(harness)
            } catch {
                gateway.finishEvents()
                await service.stopAllWatchers()
                throw error
            }
            // Watchers write through Fluent; they must be done before
            // `withTestFluent` shuts the connection pool down.
            gateway.finishEvents()
            await service.stopAllWatchers()
        }
    }

    /// Poll a persisted run until `condition` holds — the watcher writes on
    /// its own task, so assertions have to wait for it rather than sleep.
    private static func waitForRun(
        _ harness: Harness,
        runID: UUID,
        timeout: Duration = .seconds(10),
        until condition: (HermesRunDTO) -> Bool
    ) async throws -> HermesRunDTO {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let run = try await harness.service.get(tenantID: harness.tenantID, runID: runID)
            if condition(run) {
                return run
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("run never reached the expected state")
        return try await harness.service.get(tenantID: harness.tenantID, runID: runID)
    }

    // MARK: - Start + stream

    @Test
    func `start persists the run and the watcher records every event in order`() async throws {
        try await Self.withHarness { harness in
            let started = try await harness.service.start(
                tenantID: harness.tenantID,
                request: HermesRunStartRequest(prompt: "audit the vault"),
                sessionKey: "profile:default"
            )
            #expect(started.hermesRunID == harness.hermesRunID)
            #expect(started.status == .running)
            #expect(started.lastSeq == 0)

            try await harness.gateway.waitForEventSubscription()
            harness.gateway.emit(#"{"event":"run.started"}"#)
            harness.gateway.emit(#"{"event":"tool.started","tool":"shell"}"#)
            harness.gateway.emit(#"{"event":"tool.completed","tool":"shell"}"#)
            harness.gateway.emit(#"{"event":"run.completed","output":"vault is clean"}"#)
            harness.gateway.finishEvents()

            let finished = try await Self.waitForRun(harness, runID: started.id) { $0.status == .completed }
            #expect(finished.summary == "vault is clean")
            #expect(finished.finishedAt != nil)
            #expect(finished.lastEvent == "run.completed")
            #expect(finished.lastSeq == 4)

            let events = try await harness.service.events(
                tenantID: harness.tenantID,
                runID: started.id,
                afterSeq: 0
            )
            #expect(events.map(\.event) == ["run.started", "tool.started", "tool.completed", "run.completed"])
            #expect(events.map(\.seq) == [1, 2, 3, 4])
            #expect(events.last?.payload.objectValue?["output"]?.stringValue == "vault is clean")

            // Replay cursor: asking for everything after seq 2 skips the first two.
            let tail = try await harness.service.events(
                tenantID: harness.tenantID,
                runID: started.id,
                afterSeq: 2
            )
            #expect(tail.map(\.seq) == [3, 4])

            try await harness.notifier.waitForCompletions(1)
            #expect(await harness.notifier.completions.first?.status == .completed)
        }
    }

    @Test
    func `a run the tenant does not own is not readable`() async throws {
        try await Self.withHarness { harness in
            let run = try await harness.service.start(
                tenantID: harness.tenantID,
                request: HermesRunStartRequest(prompt: "mine"),
                sessionKey: nil
            )
            await #expect(throws: HermesRunsServiceError.runNotFound) {
                try await harness.service.get(tenantID: UUID(), runID: run.id)
            }
            harness.gateway.finishEvents()
        }
    }

    @Test
    func `an empty prompt is rejected before hermes is called`() async throws {
        try await Self.withHarness { harness in
            await #expect(throws: HermesRunsServiceError.emptyPrompt) {
                try await harness.service.start(
                    tenantID: harness.tenantID,
                    request: HermesRunStartRequest(prompt: "   \n "),
                    sessionKey: nil
                )
            }
            #expect(harness.gateway.recorded.isEmpty)
        }
    }

    @Test
    func `a hermes without the runs capability rejects the start`() async throws {
        try await Self.withHarness { harness in
            harness.gateway.stub(
                "GET v1/capabilities",
                json: #"{"features":{"approval_events":false,"run_events_sse":true}}"#
            )
            await #expect(throws: HermesRunsClientError.unsupported) {
                try await harness.service.start(
                    tenantID: harness.tenantID,
                    request: HermesRunStartRequest(prompt: "go"),
                    sessionKey: nil
                )
            }
            #expect(harness.gateway.requests(matching: "v1/runs").isEmpty)
        }
    }

    // MARK: - Approvals

    @Test
    func `an approval request sets pending approval, pushes once, and approving clears it`() async throws {
        try await Self.withHarness { harness in
            let started = try await harness.service.start(
                tenantID: harness.tenantID,
                request: HermesRunStartRequest(prompt: "delete the temp files"),
                sessionKey: nil
            )
            try await harness.gateway.waitForEventSubscription()
            harness.gateway.emit(#"{"event":"run.started"}"#)
            harness.gateway.emit(#"""
            {"event":"approval.request","command":"rm -rf /tmp/x","choices":["once","session","always","deny"],"tool":"shell"}
            """#)

            let waiting = try await Self.waitForRun(harness, runID: started.id) { $0.status == .waitingForApproval }
            let pending = try #require(waiting.pendingApproval)
            #expect(pending.command == "rm -rf /tmp/x")
            #expect(pending.choices == [.once, .session, .always, .deny])
            #expect(pending.extra?["tool"]?.stringValue == "shell")

            try await harness.notifier.waitForApprovals(1)
            #expect(await harness.notifier.approvals.count == 1)
            #expect(await harness.notifier.approvals.first?.pendingApproval?.command == "rm -rf /tmp/x")

            let approved = try await harness.service.approve(
                tenantID: harness.tenantID,
                runID: started.id,
                choice: .session
            )
            #expect(approved.pendingApproval == nil)
            #expect(approved.status == .running)

            let approvalCall = try #require(
                harness.gateway.requests(matching: "v1/runs/\(harness.hermesRunID)/approval").first
            )
            #expect(approvalCall.body == #"{"choice":"session"}"#)

            harness.gateway.emit(#"{"event":"run.completed","output":"cleaned"}"#)
            harness.gateway.finishEvents()
            _ = try await Self.waitForRun(harness, runID: started.id) { $0.status == .completed }
            // Exactly one approval push for one approval request.
            #expect(await harness.notifier.approvals.count == 1)
        }
    }

    @Test
    func `approving a run with nothing pending is rejected`() async throws {
        try await Self.withHarness { harness in
            let started = try await harness.service.start(
                tenantID: harness.tenantID,
                request: HermesRunStartRequest(prompt: "go"),
                sessionKey: nil
            )
            await #expect(throws: HermesRunsServiceError.approvalNotPending) {
                try await harness.service.approve(tenantID: harness.tenantID, runID: started.id, choice: .once)
            }
            #expect(harness.gateway.requests(matching: "v1/runs/\(harness.hermesRunID)/approval").isEmpty)
            harness.gateway.finishEvents()
        }
    }

    @Test
    func `an approval hermes already answered elsewhere clears the local pending state`() async throws {
        try await Self.withHarness { harness in
            harness.gateway.stub(
                "POST v1/runs/\(harness.hermesRunID)/approval",
                json: #"{"error":{"code":"approval_not_pending"}}"#,
                status: 409
            )
            let started = try await harness.service.start(
                tenantID: harness.tenantID,
                request: HermesRunStartRequest(prompt: "go"),
                sessionKey: nil
            )
            try await harness.gateway.waitForEventSubscription()
            harness.gateway.emit(#"{"event":"approval.request","command":"ls"}"#)
            _ = try await Self.waitForRun(harness, runID: started.id) { $0.pendingApproval != nil }

            await #expect(throws: HermesRunsServiceError.approvalNotPending) {
                try await harness.service.approve(tenantID: harness.tenantID, runID: started.id, choice: .once)
            }
            let cleared = try await harness.service.get(tenantID: harness.tenantID, runID: started.id)
            #expect(cleared.pendingApproval == nil)
            harness.gateway.finishEvents()
        }
    }

    // MARK: - Stop

    @Test
    func `stop asks hermes to cancel and the watcher records the cancellation`() async throws {
        try await Self.withHarness { harness in
            let started = try await harness.service.start(
                tenantID: harness.tenantID,
                request: HermesRunStartRequest(prompt: "long job"),
                sessionKey: nil
            )
            try await harness.gateway.waitForEventSubscription()
            harness.gateway.emit(#"{"event":"run.started"}"#)
            _ = try await harness.service.stop(tenantID: harness.tenantID, runID: started.id)
            #expect(harness.gateway.requests(matching: "v1/runs/\(harness.hermesRunID)/stop").count == 1)

            harness.gateway.emit(#"{"event":"run.cancelled"}"#)
            harness.gateway.finishEvents()
            let stopped = try await Self.waitForRun(harness, runID: started.id) { $0.status == .stopped }
            #expect(stopped.finishedAt != nil)
            try await harness.notifier.waitForCompletions(1)
        }
    }

    @Test
    func `stopping a run hermes has already forgotten marks it stopped locally`() async throws {
        try await Self.withHarness { harness in
            let started = try await harness.service.start(
                tenantID: harness.tenantID,
                request: HermesRunStartRequest(prompt: "long job"),
                sessionKey: nil
            )
            try await harness.gateway.waitForEventSubscription()
            harness.gateway.stub(
                "POST v1/runs/\(harness.hermesRunID)/stop",
                json: #"{"error":{"code":"run_not_found"}}"#,
                status: 404
            )
            let stopped = try await harness.service.stop(tenantID: harness.tenantID, runID: started.id)
            #expect(stopped.status == .stopped)
            #expect(stopped.finishedAt != nil)
            try await harness.notifier.waitForCompletions(1)
            harness.gateway.finishEvents()
        }
    }

    @Test
    func `stopping an already terminal run is a no-op`() async throws {
        try await Self.withHarness { harness in
            let started = try await harness.service.start(
                tenantID: harness.tenantID,
                request: HermesRunStartRequest(prompt: "quick"),
                sessionKey: nil
            )
            try await harness.gateway.waitForEventSubscription()
            harness.gateway.emit(#"{"event":"run.completed","output":"ok"}"#)
            harness.gateway.finishEvents()
            _ = try await Self.waitForRun(harness, runID: started.id) { $0.status == .completed }

            let again = try await harness.service.stop(tenantID: harness.tenantID, runID: started.id)
            #expect(again.status == .completed)
            #expect(harness.gateway.requests(matching: "v1/runs/\(harness.hermesRunID)/stop").isEmpty)
        }
    }

    // MARK: - Re-attach on boot

    @Test
    func `re-attach polls hermes for a run that outlived the process`() async throws {
        var limits = HermesRunsService.Limits()
        limits.watcher.pollInterval = .milliseconds(20)
        try await Self.withHarness(limits: limits) { harness in
            // A row left behind by a previous process — no watcher owns it.
            let run = HermesRun(
                tenantID: harness.tenantID,
                hermesRunID: harness.hermesRunID,
                status: .running,
                prompt: "survived a restart",
                startedAt: Date()
            )
            try await run.save(on: harness.fluent.db())
            let runID = try run.requireID()

            harness.gateway.stub(
                "GET v1/runs/\(harness.hermesRunID)",
                json: #"{"status":"completed","output":"finished while we were down"}"#
            )
            await harness.service.reattach()
            #expect(await harness.service.isWatching(runID: runID))

            let finished = try await Self.waitForRun(harness, runID: runID) { $0.status == .completed }
            #expect(finished.summary == "finished while we were down")
            // Re-attach polls; it never re-subscribes to the SSE feed, which
            // Hermes tears down when the first subscriber disconnects.
            #expect(harness.gateway.eventsSubscriptionCount == 0)
            try await harness.notifier.waitForCompletions(1)
        }
    }

    @Test
    func `re-attach marks a run hermes has expired as lost`() async throws {
        var limits = HermesRunsService.Limits()
        limits.watcher.pollInterval = .milliseconds(20)
        try await Self.withHarness(limits: limits) { harness in
            let run = HermesRun(
                tenantID: harness.tenantID,
                hermesRunID: "run_gone",
                status: .running,
                prompt: "hermes forgot me",
                startedAt: Date()
            )
            try await run.save(on: harness.fluent.db())
            let runID = try run.requireID()

            // No stub for `GET v1/runs/run_gone` — the fake 404s with
            // `run_not_found`, exactly as an expired run does.
            await harness.service.reattach()
            let lost = try await Self.waitForRun(harness, runID: runID) { $0.status == .lost }
            #expect(lost.error != nil)
            try await harness.notifier.waitForCompletions(1)
        }
    }

    @Test
    func `a run older than the hermes TTL is marked lost without contacting hermes`() async throws {
        var limits = HermesRunsService.Limits()
        limits.reattachWindow = 300
        try await Self.withHarness(limits: limits) { harness in
            let run = HermesRun(
                tenantID: harness.tenantID,
                hermesRunID: "run_ancient",
                status: .waitingForApproval,
                prompt: "started an hour ago",
                startedAt: Date().addingTimeInterval(-3600)
            )
            try await run.save(on: harness.fluent.db())
            let runID = try run.requireID()

            await harness.service.reattach()
            #expect(await !harness.service.isWatching(runID: runID))

            let lost = try await harness.service.get(tenantID: harness.tenantID, runID: runID)
            #expect(lost.status == .lost)
            #expect(lost.pendingApproval == nil)
            #expect(lost.finishedAt != nil)
            #expect(harness.gateway.recorded.isEmpty)

            // The loss is persisted as an event so an SSE consumer sees the end.
            let events = try await harness.service.events(tenantID: harness.tenantID, runID: runID, afterSeq: 0)
            #expect(events.map(\.event) == ["watcher.lost"])
            try await harness.notifier.waitForCompletions(1)
        }
    }

    @Test
    func `re-attach skips runs that already have a watcher`() async throws {
        try await Self.withHarness { harness in
            let started = try await harness.service.start(
                tenantID: harness.tenantID,
                request: HermesRunStartRequest(prompt: "already watched"),
                sessionKey: nil
            )
            try await harness.gateway.waitForEventSubscription()
            await harness.service.reattach()
            #expect(await harness.service.activeWatcherCount == 1)
            #expect(harness.gateway.eventsSubscriptionCount == 1)

            harness.gateway.emit(#"{"event":"run.completed"}"#)
            harness.gateway.finishEvents()
            _ = try await Self.waitForRun(harness, runID: started.id) { $0.status == .completed }
        }
    }

    // MARK: - Bounds

    @Test
    func `the per-tenant watcher bound rejects further concurrent runs`() async throws {
        var limits = HermesRunsService.Limits()
        limits.maxWatchersPerTenant = 2
        try await Self.withHarness(limits: limits) { harness in
            // Distinct run ids so each start makes its own row.
            for index in 0 ..< 2 {
                harness.gateway.stub("POST v1/runs", json: #"{"run_id":"run_\#(index)"}"#, status: 202)
                _ = try await harness.service.start(
                    tenantID: harness.tenantID,
                    request: HermesRunStartRequest(prompt: "job \(index)"),
                    sessionKey: nil
                )
            }
            #expect(await harness.service.activeWatcherCount(tenantID: harness.tenantID) == 2)
            await #expect(throws: HermesRunsServiceError.tooManyActiveRuns) {
                try await harness.service.start(
                    tenantID: harness.tenantID,
                    request: HermesRunStartRequest(prompt: "one too many"),
                    sessionKey: nil
                )
            }
            harness.gateway.finishEvents()
        }
    }

    @Test
    func `list returns the tenant's runs newest first and caps the limit`() async throws {
        try await Self.withHarness { harness in
            let now = Date()
            for index in 0 ..< 3 {
                let run = HermesRun(
                    tenantID: harness.tenantID,
                    hermesRunID: "run_list_\(index)",
                    status: .completed,
                    prompt: "job \(index)",
                    startedAt: now.addingTimeInterval(Double(index))
                )
                try await run.save(on: harness.fluent.db())
            }
            let runs = try await harness.service.list(tenantID: harness.tenantID, limit: 100)
            #expect(runs.map(\.prompt) == ["job 2", "job 1", "job 0"])

            let limited = try await harness.service.list(tenantID: harness.tenantID, limit: 1)
            #expect(limited.map(\.prompt) == ["job 2"])
            #expect(try await harness.service.list(tenantID: UUID(), limit: 10).isEmpty)
        }
    }

    // MARK: - EventBus fan-out

    @Test
    func `every persisted event is published on the bus for the SSE feed`() async throws {
        try await Self.withHarness { harness in
            let received = AsyncStreamCollector<HermesRunEventPayload>()
            let subscription = harness.eventBus.subscribe(eventType: .hermesRunEvent)
            let collector = Task {
                for await event in subscription {
                    guard let payload = HermesRunEventPayload(event) else { continue }
                    await received.append(payload)
                }
            }
            let started = try await harness.service.start(
                tenantID: harness.tenantID,
                request: HermesRunStartRequest(prompt: "watch the bus"),
                sessionKey: nil
            )
            try await harness.gateway.waitForEventSubscription()
            harness.gateway.emit(#"{"event":"run.started"}"#)
            harness.gateway.emit(#"{"event":"run.completed","output":"ok"}"#)
            harness.gateway.finishEvents()
            _ = try await Self.waitForRun(harness, runID: started.id) { $0.status == .completed }

            try await received.wait(forAtLeast: 3)
            collector.cancel()
            let names = await received.values.map(\.event)
            #expect(names.contains("run.accepted"))
            #expect(names.contains("run.started"))
            #expect(names.contains("run.completed"))
            #expect(await received.values.allSatisfy { $0.runID == started.id })
        }
    }
}

/// Small accumulator so a bus subscription can be asserted from the test
/// body without sharing mutable state across tasks.
actor AsyncStreamCollector<Value: Sendable> {
    private(set) var values: [Value] = []

    func append(_ value: Value) {
        values.append(value)
    }

    func wait(forAtLeast count: Int, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if values.count >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("only \(values.count) of \(count) values arrived")
    }
}
