@testable import App
import Foundation
import Logging
import LuminaVaultShared
import Testing

/// HER-252 — proves the failover notice sink fires + carries the right
/// `(original, fallback, reasonCode)` when `RoutedLLMTransport` advances
/// candidates on a `.creditExhausted` failure. Companion to
/// `RoutedLLMTransportTests` which already covers the success-path
/// failover, but doesn't observe the notice.
@Suite(.serialized)
struct RoutedLLMTransportFallbackTests {
    actor StubAdapter: ProviderAdapter {
        enum Outcome {
            case success(Data)
            case providerError(ProviderError)
        }

        nonisolated let kind: ProviderKind
        private var outcomes: [Outcome]

        init(kind: ProviderKind, outcomes: [Outcome]) {
            self.kind = kind
            self.outcomes = outcomes
        }

        func chatCompletions(payload _: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
            guard !outcomes.isEmpty else {
                throw ProviderError.transient(provider: kind, status: 0, body: "stub exhausted")
            }
            switch outcomes.removeFirst() {
            case let .success(data): return data
            case let .providerError(error): throw error
            }
        }
    }

    struct FixedRouter: ModelRouter {
        let decision: RouteDecision
        func pick(forModel _: String?, capability _: LLMCapabilityLevel, user _: User?) async -> RouteDecision {
            decision
        }
    }

    /// Thread-safe collector for notices yielded into the task-local sink.
    actor NoticeCollector {
        var notices: [ProviderFailoverNotice] = []
        func record(_ notice: ProviderFailoverNotice) {
            notices.append(notice)
        }
    }

    @Test
    func `credit exhaustion fires failover notice and falls over`() async throws {
        let primary = StubAdapter(
            kind: .xai,
            outcomes: [.providerError(.creditExhausted(provider: .xai, status: 403, body: "insufficient_quota"))],
        )
        let fallback = StubAdapter(kind: .openRouter, outcomes: [.success(Data("FALLBACK".utf8))])
        let registry = ProviderRegistry(adapters: [primary, fallback], logger: Logger(label: "test"))
        let decision = RouteDecision(
            primary: ModelRoute(provider: .xai, modelID: "grok-4"),
            fallbacks: [ModelRoute(provider: .openRouter, modelID: "qwen-2.5-72b")],
        )
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: decision),
            logger: Logger(label: "test"),
        )
        let collector = NoticeCollector()
        let sink: @Sendable (ProviderFailoverNotice) -> Void = { notice in
            Task { await collector.record(notice) }
        }

        let result = try await FailoverNoticeContext.$sink.withValue(sink) {
            try await transport.chatCompletions(
                payload: Data("{\"model\":\"grok-4\",\"messages\":[]}".utf8),
                sessionKey: "alice",
                sessionID: nil,
            )
        }
        #expect(String(data: result, encoding: .utf8) == "FALLBACK")

        // Give the unstructured Task that posted into the collector a
        // beat to land before we read it.
        try await Task.sleep(for: .milliseconds(50))
        let notices = await collector.notices
        #expect(notices.count == 1, "exactly one notice per failover")
        let notice = try #require(notices.first)
        #expect(notice.originalProvider == .xai)
        #expect(notice.originalModel == "grok-4")
        #expect(notice.fallbackProvider == .openRouter)
        #expect(notice.fallbackModel == "qwen-2.5-72b")
        #expect(notice.reasonCode == "credit_exhausted")
        #expect(notice.userMessage.contains("Grok"))
        #expect(notice.statusCode == 403)
    }

    @Test
    func `no notice when primary succeeds`() async throws {
        let primary = StubAdapter(kind: .anthropic, outcomes: [.success(Data("OK".utf8))])
        let registry = ProviderRegistry(adapters: [primary], logger: Logger(label: "test"))
        let decision = RouteDecision(
            primary: ModelRoute(provider: .anthropic, modelID: "claude-sonnet-4.6"),
            fallbacks: [],
        )
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: decision),
            logger: Logger(label: "test"),
        )
        let collector = NoticeCollector()
        let sink: @Sendable (ProviderFailoverNotice) -> Void = { notice in
            Task { await collector.record(notice) }
        }
        _ = try await FailoverNoticeContext.$sink.withValue(sink) {
            try await transport.chatCompletions(
                payload: Data("{\"model\":\"claude-sonnet-4.6\",\"messages\":[]}".utf8),
                sessionKey: "alice",
                sessionID: nil,
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        let notices = await collector.notices
        #expect(notices.isEmpty, "no failover = no notice")
    }

    @Test
    func `chained failover only notices the last transition`() async throws {
        // primary fails → secondary fails → tertiary succeeds. Should
        // emit a notice describing the SUCCESSFUL transition only.
        let primary = StubAdapter(
            kind: .xai,
            outcomes: [.providerError(.creditExhausted(provider: .xai, status: 402, body: nil))],
        )
        let secondary = StubAdapter(
            kind: .anthropic,
            outcomes: [.providerError(.transient(provider: .anthropic, status: 429, body: nil))],
        )
        let tertiary = StubAdapter(kind: .openRouter, outcomes: [.success(Data("LAST".utf8))])
        let registry = ProviderRegistry(adapters: [primary, secondary, tertiary], logger: Logger(label: "test"))
        let decision = RouteDecision(
            primary: ModelRoute(provider: .xai, modelID: "grok-4"),
            fallbacks: [
                ModelRoute(provider: .anthropic, modelID: "claude-sonnet-4.6"),
                ModelRoute(provider: .openRouter, modelID: "qwen-2.5-72b"),
            ],
        )
        let transport = RoutedLLMTransport(
            registry: registry,
            router: FixedRouter(decision: decision),
            logger: Logger(label: "test"),
        )
        let collector = NoticeCollector()
        let sink: @Sendable (ProviderFailoverNotice) -> Void = { notice in
            Task { await collector.record(notice) }
        }
        _ = try await FailoverNoticeContext.$sink.withValue(sink) {
            try await transport.chatCompletions(
                payload: Data("{\"model\":\"grok-4\",\"messages\":[]}".utf8),
                sessionKey: "alice",
                sessionID: nil,
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        let notices = await collector.notices
        #expect(notices.count == 1, "only the successful transition emits a notice")
        let notice = try #require(notices.first)
        // The notice describes the (last failure → success) hop.
        #expect(notice.originalProvider == .anthropic)
        #expect(notice.fallbackProvider == .openRouter)
        #expect(notice.reasonCode == "rate_limit")
    }
}
