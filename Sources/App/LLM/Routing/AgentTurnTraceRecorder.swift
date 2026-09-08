import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared

/// Writes one `agent_turn_traces` row per routed call.
///
/// Fire-and-forget by contract. A trace is an explanation of work that already
/// succeeded; failing or delaying the user's answer to record it would trade
/// the thing that matters for the thing that describes it.
actor AgentTurnTraceRecorder {
    private let fluent: Fluent
    private let logger: Logger

    init(fluent: Fluent, logger: Logger) {
        self.fluent = fluent
        self.logger = logger
    }

    struct Turn: Sendable {
        let tenantID: UUID
        let conversationMessageID: UUID?
        let provider: ProviderID
        let model: String
        /// nil when the response body could not be read — distinct from an
        /// empty list, which means the model genuinely called nothing.
        let toolNames: [String]?
        let failoverCount: Int
        let tokensIn: Int
        let tokensOut: Int
        let estimatedCostUsdMicros: Int64
        let latencyMs: Int
        let credentialMode: LLMBrainMode?
    }

    func record(_ turn: Turn) async {
        let row = AgentTurnTrace(
            tenantID: turn.tenantID,
            conversationMessageID: turn.conversationMessageID,
            provider: turn.provider.rawValue,
            model: turn.model,
            toolCalls: turn.toolNames.map { AgentToolCalls(names: $0) },
            failoverCount: max(0, turn.failoverCount),
            tokensIn: Int64(max(0, turn.tokensIn)),
            tokensOut: Int64(max(0, turn.tokensOut)),
            estimatedCostUsdMicros: max(0, turn.estimatedCostUsdMicros),
            latencyMs: Int64(max(0, turn.latencyMs)),
            credentialMode: turn.credentialMode?.rawValue
        )
        do {
            try await row.save(on: fluent.db())
        } catch {
            logger.debug("agent turn trace not recorded: \(error)")
        }
    }
}
