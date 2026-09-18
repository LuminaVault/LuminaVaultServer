import Foundation
import LuminaVaultShared

/// How big the prompt is, and how big the window is, for the context gauge.
///
/// Both numbers are estimates and the client is told so by their absence
/// rather than by a flag: when either cannot be determined the field is left
/// nil and the client shows a receipt with no gauge. A wrong gauge is worse
/// than no gauge, because a user cannot tell a wrong one from a right one.
enum PromptSizeEstimator {
    /// Characters per token. There is no tokenizer on this path and adding
    /// one per provider is a large amount of machinery for a progress bar.
    /// Four is the usual rule of thumb for English prose and code, and the
    /// gauge only has to be right enough to say "getting full".
    ///
    /// It will read low for languages with denser tokenization. That is
    /// acceptable for a gauge and would not be for billing, which is why
    /// cost still comes from the provider's own usage numbers.
    static let charactersPerToken = 4

    /// Estimated size of an assembled prompt.
    static func estimateTokens(of messages: [ChatMessage]) -> Int {
        // Per-message overhead for role framing, which every provider adds in
        // some form. Cheap to include and stops a long thread of one-word
        // turns reading as almost empty.
        let perMessageOverhead = 4
        let characters = messages.reduce(0) { $0 + $1.content.count }
        return characters / charactersPerToken + messages.count * perMessageOverhead
    }

    /// The routed model's context window, or nil when the catalogue does not
    /// know the model. Nil is the honest answer: inventing a default would
    /// put a confident, wrong percentage on screen.
    static func contextWindow(forModel model: String) -> Int? {
        guard !model.isEmpty else { return nil }
        for provider in ProviderID.allCases {
            if let match = LLMModelCatalog.models(for: provider).first(where: { $0.id == model }) {
                return match.contextWindow
            }
        }
        // Routed model ids often carry a provider prefix (`openai/gpt-4o`).
        if let slash = model.lastIndex(of: "/") {
            return contextWindow(forModel: String(model[model.index(after: slash)...]))
        }
        return nil
    }
}
