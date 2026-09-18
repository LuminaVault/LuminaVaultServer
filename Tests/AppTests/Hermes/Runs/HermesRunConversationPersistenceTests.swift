@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// An escalated chat turn is answered by a run, and the run's watcher is what
/// writes that answer into the transcript.
///
/// Without this the answer exists only while the stream is live: reopen the
/// thread, or open it on another device, and the conversation shows a system
/// marker linking to a run where the reply should be. The transcript has to
/// stand on its own.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct HermesRunConversationPersistenceTests {
    private struct Harness: Sendable {
        let fluent: Fluent
        let gateway: FakeHermesRunsGateway
        let service: HermesRunsService
        let tenantID: UUID
        let conversationID: UUID
    }

    private static func withHarness(_ body: (Harness) async throws -> Void) async throws {
        try await withTestFluent(label: "test.hermes.runs.conversation") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let user = User(
                email: "runconv-\(suffix)@test.luminavault",
                username: "runconv-\(suffix)",
                passwordHash: "stub"
            )
            try await user.save(on: fluent.db())
            try await DefaultAuthService.ensurePersonalVault(for: user, on: fluent.db())
            let tenantID = try user.requireID()

            let conversation = Conversation(tenantID: tenantID, title: "escalated")
            try await conversation.save(on: fluent.db())

            let gateway = FakeHermesRunsGateway.accepting(runID: "run_conv")
            let logger = Logger(label: "test.hermes.runs.conversation")
            let service = HermesRunsService(
                fluent: fluent,
                eventBus: EventBus(logger: Logger(label: "test.eventbus")),
                notifier: RecordingRunPushNotifier(),
                resolve: { _ in
                    .init(baseURL: URL(string: "http://hermes.test")!, authHeader: nil, isUserOverride: false)
                },
                makeClient: { _, sessionKey in gateway.client(sessionKey: sessionKey) },
                logger: logger
            )
            let harness = try Harness(
                fluent: fluent,
                gateway: gateway,
                service: service,
                tenantID: tenantID,
                conversationID: conversation.requireID()
            )
            do {
                try await body(harness)
            } catch {
                gateway.finishEvents()
                await service.stopAllWatchers()
                throw error
            }
            gateway.finishEvents()
            await service.stopAllWatchers()
        }
    }

    private static func assistantMessages(_ harness: Harness) async throws -> [ConversationMessage] {
        try await ConversationMessage.query(on: harness.fluent.db())
            .filter(\.$conversationID == harness.conversationID)
            .filter(\.$role == ConversationMessageRole.assistant.rawValue)
            .all()
    }

    /// Polls, because the watcher writes on its own task.
    private static func waitForAssistantTurn(
        _ harness: Harness,
        timeout: Duration = .seconds(10)
    ) async throws -> ConversationMessage? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let first = try await assistantMessages(harness).first {
                return first
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    @Test("A completed run writes its answer into the conversation")
    func completedRunCommitsAnswer() async throws {
        try await Self.withHarness { harness in
            let started = try await harness.service.start(
                tenantID: harness.tenantID,
                request: HermesRunStartRequest(prompt: "tidy the vault", conversationID: harness.conversationID),
                sessionKey: nil
            )
            try await harness.gateway.waitForEventSubscription()
            harness.gateway.emit(#"{"event":"run.started"}"#)
            harness.gateway.emit(#"{"event":"tool.started","tool":"shell"}"#)
            harness.gateway.emit(#"{"event":"tool.completed","tool":"shell"}"#)
            harness.gateway.emit(#"{"event":"tool.started","tool":"write_file"}"#)
            harness.gateway.emit(#"{"event":"run.completed","output":"vault is clean"}"#)
            harness.gateway.finishEvents()

            let message = try #require(try await Self.waitForAssistantTurn(harness))
            #expect(message.content == "vault is clean")
            #expect(message.hermesRunID == started.id)
            // Counts `tool.started`, so a tool that never returned still
            // shows as attempted rather than vanishing.
            #expect(message.toolCallCount == 2)
        }
    }

    /// The watcher re-attaches to non-terminal runs after a restart and
    /// replays from its cursor, so a run that finished while the process was
    /// down reaches the commit again. Writing twice would show the user the
    /// same answer twice.
    @Test("Committing the answer twice is a no-op")
    func commitIsIdempotent() async throws {
        try await Self.withHarness { harness in
            let started = try await harness.service.start(
                tenantID: harness.tenantID,
                request: HermesRunStartRequest(prompt: "tidy", conversationID: harness.conversationID),
                sessionKey: nil
            )
            try await harness.gateway.waitForEventSubscription()
            harness.gateway.emit(#"{"event":"run.started"}"#)
            harness.gateway.emit(#"{"event":"run.completed","output":"done"}"#)
            harness.gateway.finishEvents()

            _ = try #require(try await Self.waitForAssistantTurn(harness))

            // Re-run the commit directly, which is what a re-attached watcher
            // reaching the same terminal edge would do.
            let run = try #require(
                try await HermesRun.query(on: harness.fluent.db())
                    .filter(\.$id == started.id)
                    .first()
            )
            let watcher = try HermesRunWatcher(
                run: run,
                mode: .poll,
                client: harness.gateway.client(sessionKey: nil),
                store: HermesRunStore(
                    fluent: harness.fluent,
                    eventBus: EventBus(logger: Logger(label: "test.eventbus.replay")),
                    logger: Logger(label: "test.replay")
                ),
                notifier: RecordingRunPushNotifier(),
                config: HermesRunWatcher.Config(),
                logger: Logger(label: "test.replay")
            )
            await watcher.commitConversationTurn(run: run, at: Date())

            #expect(try await Self.assistantMessages(harness).count == 1)
        }
    }

    /// A failed run is reported through the run's own status. Writing an
    /// assistant turn for it would put an error in the transcript dressed as
    /// an answer.
    @Test("A failed run writes no assistant turn")
    func failedRunWritesNothing() async throws {
        try await Self.withHarness { harness in
            _ = try await harness.service.start(
                tenantID: harness.tenantID,
                request: HermesRunStartRequest(prompt: "break", conversationID: harness.conversationID),
                sessionKey: nil
            )
            try await harness.gateway.waitForEventSubscription()
            harness.gateway.emit(#"{"event":"run.started"}"#)
            harness.gateway.emit(#"{"event":"run.failed","error":"tool exploded"}"#)
            harness.gateway.finishEvents()

            _ = try await Self.waitForAssistantTurn(harness, timeout: .seconds(2))
            #expect(try await Self.assistantMessages(harness).isEmpty)
        }
    }

    /// A completed run with nothing to say leaves the transcript alone
    /// rather than committing a blank bubble.
    @Test("A completed run with an empty summary writes nothing")
    func emptySummaryWritesNothing() async throws {
        try await Self.withHarness { harness in
            _ = try await harness.service.start(
                tenantID: harness.tenantID,
                request: HermesRunStartRequest(prompt: "nothing", conversationID: harness.conversationID),
                sessionKey: nil
            )
            try await harness.gateway.waitForEventSubscription()
            harness.gateway.emit(#"{"event":"run.started"}"#)
            harness.gateway.emit(#"{"event":"run.completed","output":"   "}"#)
            harness.gateway.finishEvents()

            _ = try await Self.waitForAssistantTurn(harness, timeout: .seconds(2))
            #expect(try await Self.assistantMessages(harness).isEmpty)
        }
    }

    /// A run started from the Agent Runs screen has no conversation. It must
    /// not write into one.
    @Test("A run with no conversation writes nothing")
    func standaloneRunWritesNothing() async throws {
        try await Self.withHarness { harness in
            _ = try await harness.service.start(
                tenantID: harness.tenantID,
                request: HermesRunStartRequest(prompt: "standalone"),
                sessionKey: nil
            )
            try await harness.gateway.waitForEventSubscription()
            harness.gateway.emit(#"{"event":"run.completed","output":"done"}"#)
            harness.gateway.finishEvents()

            _ = try await Self.waitForAssistantTurn(harness, timeout: .seconds(2))
            #expect(try await Self.assistantMessages(harness).isEmpty)
        }
    }
}
