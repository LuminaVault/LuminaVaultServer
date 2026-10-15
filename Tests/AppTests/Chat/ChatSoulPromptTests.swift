@testable import App
import Foundation
import Testing

/// SOUL.md reaches the prompt only when the caller passes it — the
/// controller does that for BYOK and local turns, never for turns Hermes
/// handles, since Hermes adds SOUL itself.
struct ChatSoulPromptTests {
    @Test
    func `the prompt carries SOUL when given and not otherwise`() {
        let with = ConversationController.buildPrompt(history: [], hits: [], soul: "Prefers British spelling.")
        let without = ConversationController.buildPrompt(history: [], hits: [])
        #expect(with.first?.content.contains("Prefers British spelling.") == true)
        #expect(without.first?.content.contains("SOUL.md") == false)
    }

    @Test
    func `a long SOUL is capped and says so`() {
        let long = String(repeating: "a", count: ConversationController.maxSoulCharacters + 50)
        let capped = ConversationController.capped(long, maxCharacters: ConversationController.maxSoulCharacters)
        #expect(capped.hasSuffix("…(truncated)"))
        #expect(capped.count < long.count)
        #expect(ConversationController.capped("short", maxCharacters: 10) == "short")
    }
}
