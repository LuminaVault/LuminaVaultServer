import Foundation
import LuminaVaultShared

/// HER-300 — test-only chat adapter that returns a canned, deterministic
/// completion with no network I/O. Selected exclusively via
/// `llm.provider=stub` (see `App+build`); the branch is unreachable in
/// prod unless someone sets that env var.
///
/// Slots in under `.hermesGateway` by default so it backs the
/// `TableModelRouter`'s last-resort route — the one a `managed`-mode user
/// always resolves to (`UserPreferenceModelRouter` delegates managed
/// routing entirely to the table). That lets an e2e test drive the full
/// auth → preferences → routing → reply path without a real upstream.
///
/// Emits the OpenAI/Hermes chat-completions wire shape
/// (`HermesUpstreamResponse`) that `RoutedHermesLLMService` decodes, so
/// the response round-trips into a `ChatResponse` exactly like a real
/// provider.
struct StubChatAdapter: ProviderAdapter {
    let kind: ProviderKind
    let replyContent: String
    let replyModel: String

    init(
        kind: ProviderKind = .hermesGateway,
        replyContent: String = "Hello from the LuminaVault default brain.",
        replyModel: String = "stub-default-brain"
    ) {
        self.kind = kind
        self.replyContent = replyContent
        self.replyModel = replyModel
    }

    func chatCompletions(payload _: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
        let response = HermesUpstreamResponse(
            id: "stub-\(UUID().uuidString)",
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: replyModel,
            choices: [
                HermesUpstreamChoice(
                    index: 0,
                    message: ChatMessage(role: "assistant", content: replyContent),
                    finishReason: "stop"
                ),
            ],
            usage: HermesUpstreamUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
        )
        return try JSONEncoder().encode(response)
    }
}
