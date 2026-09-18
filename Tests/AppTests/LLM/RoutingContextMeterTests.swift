@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// The numbers behind the chat context gauge, and the rule that a wrong gauge
/// is worse than no gauge.
@Suite("Routing context meter")
struct RoutingContextMeterTests {
    private typealias Estimator = PromptSizeEstimator

    @Test("Prompt size grows with the prompt")
    func estimateGrows() {
        let small = Estimator.estimateTokens(of: [ChatMessage(role: "user", content: "hi")])
        let large = Estimator.estimateTokens(of: [
            ChatMessage(role: "user", content: String(repeating: "word ", count: 1000)),
        ])
        #expect(small > 0)
        #expect(large > small * 10)
    }

    /// A long thread of short turns is not almost-empty: every provider adds
    /// role framing per message, and ignoring it would make the gauge read
    /// far too low exactly when the window is filling up.
    @Test("Many short messages cost more than one message of the same text")
    func perMessageOverheadCounts() {
        let many = (0 ..< 50).map { _ in ChatMessage(role: "user", content: "ok") }
        let one = [ChatMessage(role: "user", content: String(repeating: "ok", count: 50))]
        #expect(Estimator.estimateTokens(of: many) > Estimator.estimateTokens(of: one))
    }

    @Test("An empty prompt estimates to nothing")
    func emptyPrompt() {
        #expect(Estimator.estimateTokens(of: []) == 0)
    }

    @Test("A known model resolves its context window")
    func knownModelWindow() {
        #expect(Estimator.contextWindow(forModel: "gpt-4o-mini") == 128_000)
    }

    /// Routed ids often carry a provider prefix.
    @Test("A provider-prefixed model id still resolves")
    func prefixedModelWindow() {
        #expect(Estimator.contextWindow(forModel: "openai/gpt-4o-mini") == 128_000)
    }

    /// Nil is the honest answer. A default would put a confident, wrong
    /// percentage on screen, and the user cannot tell a wrong gauge from a
    /// right one.
    @Test("An unknown model yields no window rather than a guess")
    func unknownModelWindow() {
        #expect(Estimator.contextWindow(forModel: "some-model-nobody-has-heard-of") == nil)
        #expect(Estimator.contextWindow(forModel: "") == nil)
    }

    // MARK: - Disclosure

    private func routingEvent(promptTokens: Int?, windowTokens: Int?) -> QueryStreamEvent {
        .routing(RouterRoutingEventDTO(
            executionID: UUID(),
            phase: .selected,
            profileID: UUID(),
            profileName: "Auto",
            taskType: .general,
            strategy: .sequential,
            activeRoutes: [],
            promptTokens: promptTokens,
            contextWindowTokens: windowTokens,
            droppedHistoryTurns: 2
        ))
    }

    /// A window size identifies a model as surely as naming it: 200k against
    /// 1M narrows the field to a handful. Hidden disclosure must strip it.
    @Test("Hidden disclosure strips the context window")
    func hiddenStripsWindow() throws {
        let scrubbed = try #require(
            ModelDisclosurePolicy.scrub(routingEvent(promptTokens: 900, windowTokens: 1_000_000), disclosure: .hidden)
        )
        guard case let .routing(routing) = scrubbed else {
            Issue.record("expected a routing event")
            return
        }
        #expect(routing.contextWindowTokens == nil)
    }

    /// How much the user said reveals nothing about which model heard it,
    /// and the gauge is useless without it.
    @Test("Hidden disclosure keeps the prompt size and the dropped-turn count")
    func hiddenKeepsPromptTokens() throws {
        let scrubbed = try #require(
            ModelDisclosurePolicy.scrub(routingEvent(promptTokens: 900, windowTokens: 1_000_000), disclosure: .hidden)
        )
        guard case let .routing(routing) = scrubbed else {
            Issue.record("expected a routing event")
            return
        }
        #expect(routing.promptTokens == 900)
        #expect(routing.droppedHistoryTurns == 2)
    }

    @Test("Visible disclosure passes both numbers through")
    func visibleKeepsEverything() throws {
        let scrubbed = try #require(
            ModelDisclosurePolicy.scrub(routingEvent(promptTokens: 900, windowTokens: 1_000_000), disclosure: .visible)
        )
        guard case let .routing(routing) = scrubbed else {
            Issue.record("expected a routing event")
            return
        }
        #expect(routing.promptTokens == 900)
        #expect(routing.contextWindowTokens == 1_000_000)
    }

    @Test("Hidden disclosure strips the window from the usage receipt too")
    func hiddenStripsUsageWindow() throws {
        let usage = QueryStreamEvent.usage(RouterUsageDTO(
            executionID: UUID(),
            provider: .openai,
            model: "gpt-4o-mini",
            tokensIn: 100,
            tokensOut: 200,
            estimatedCostUsdMicros: 5,
            latencyMs: 300,
            usageEstimated: false,
            contextWindowTokens: 128_000,
            toolCallCount: 3
        ))
        let scrubbed = try #require(ModelDisclosurePolicy.scrub(usage, disclosure: .hidden))
        guard case let .usage(result) = scrubbed else {
            Issue.record("expected a usage event")
            return
        }
        #expect(result.contextWindowTokens == nil)
        #expect(result.model == nil)
        // The tool count is not a model fingerprint and the receipt needs it.
        #expect(result.toolCallCount == 3)
    }
}
