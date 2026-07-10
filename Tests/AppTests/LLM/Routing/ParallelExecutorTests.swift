@testable import App
import Foundation
import Logging
import LuminaVaultShared
import Testing

@Suite("ParallelExecutor", .serialized, .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct ParallelExecutorTests {
    @Test
    func `consensus streams every candidate and persists synthesis in result`() async throws {
        let registry = ProviderRegistry(
            adapters: [
                StubChatAdapter(kind: .openai, replyContent: "OpenAI answer", replyModel: "gpt-5"),
                StubChatAdapter(kind: .anthropic, replyContent: "Claude answer", replyModel: "claude-sonnet-4-6"),
                StubChatAdapter(kind: .xai, replyContent: "Grok answer", replyModel: "grok-4"),
            ],
            logger: Logger(label: "test")
        )
        let events = EventBox()
        let completion = try await CerberusStreamContext.$sink.withValue({ events.append($0) }) {
            try await ParallelExecutor(registry: registry, logger: Logger(label: "test"), store: nil).execute(
                payload: Self.payload,
                sessionKey: UUID().uuidString,
                sessionID: nil,
                metadata: Self.metadata(strategy: .consensus)
            )
        }

        #expect(completion.strategy == .consensus)
        #expect(completion.status == .completed)
        #expect(completion.outputs.count == 4)
        #expect(events.parallel.count(where: { $0.kind == .outputDelta }) == 3)
        #expect(events.parallel.last?.kind == .executionCompleted)
    }

    @Test
    func `auto reasoning performs one debate revision round`() async throws {
        let registry = ProviderRegistry(
            adapters: [
                StubChatAdapter(kind: .openai, replyContent: "A", replyModel: "gpt-5"),
                StubChatAdapter(kind: .anthropic, replyContent: "B", replyModel: "claude-sonnet-4-6"),
                StubChatAdapter(kind: .xai, replyContent: "C", replyModel: "grok-4"),
            ],
            logger: Logger(label: "test")
        )
        let completion = try await ParallelExecutor(
            registry: registry,
            logger: Logger(label: "test"),
            store: nil
        ).execute(
            payload: Self.payload,
            sessionKey: UUID().uuidString,
            sessionID: nil,
            metadata: Self.metadata(strategy: .auto, task: .reasoning)
        )

        #expect(completion.strategy == .debate)
        #expect(completion.outputs.count(where: { $0.stage == .answer }) == 3)
        #expect(completion.outputs.count(where: { $0.stage == .revision }) == 3)
        #expect(completion.outputs.count(where: { $0.stage == .synthesis }) == 1)
    }

    private static let payload = Data(#"{"model":"router-auto","messages":[{"role":"user","content":"Compare the options"}]}"#.utf8)

    private static func metadata(
        strategy: ParallelStrategyDTO,
        task: RouterTaskType = .general
    ) -> CerberusDecisionMetadata {
        let routes = [
            RouterModelRouteDTO(provider: .openai, model: "gpt-5"),
            RouterModelRouteDTO(provider: .anthropic, model: "claude-sonnet-4-6"),
            RouterModelRouteDTO(provider: .xai, model: "grok-4"),
        ]
        return CerberusDecisionMetadata(
            executionID: UUID(),
            tenantID: UUID(),
            profileID: UUID(),
            profileName: "Test",
            ruleID: nil,
            taskType: task,
            surface: .chat,
            spaceID: nil,
            conversationID: nil,
            strategy: .ensemble,
            parallelStrategy: strategy,
            participants: nil,
            routes: routes,
            synthesisRoute: routes[0],
            minimumSuccessfulResults: 2,
            retryPolicy: .fast,
            predictedCostUsdMicros: 1,
            budgetReservationUsdMicros: 1,
            budgetDenied: false,
            mode: .managed
        )
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [QueryStreamEvent] = []

    var parallel: [ParallelStreamEventDTO] {
        lock.withLock {
            events.compactMap { event in
                guard case let .parallel(progress) = event else { return nil }
                return progress
            }
        }
    }

    func append(_ event: QueryStreamEvent) {
        lock.withLock { events.append(event) }
    }
}
