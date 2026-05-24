@testable import App
import Testing

/// HER-37 — scaffold-level guarantees for the suggestions stub. Locks in
/// the contract iOS depends on (non-empty list, no blank entries) until
/// HER-37a wires per-user generation.
struct SuggestionsControllerTests {
    @Test
    func `defaults are non empty`() {
        #expect(!SuggestionsController.defaults.isEmpty)
    }

    @Test
    func `defaults are all non blank`() {
        for suggestion in SuggestionsController.defaults {
            #expect(!suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
