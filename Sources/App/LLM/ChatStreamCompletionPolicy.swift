import Foundation
import LuminaVaultShared

enum ChatStreamCompletionPolicy {
    static let emptyResponseMessage = "Lumina did not receive a model response. Check Hermes provider/model configuration."

    static func emptyCompletionEvent(
        assistantBuffer: String,
        tokenCount: Int,
    ) -> QueryStreamEvent? {
        let hasNoTokens = tokenCount == 0
        let hasNoContent = assistantBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasNoTokens || hasNoContent else { return nil }
        return .error(emptyResponseMessage)
    }
}
