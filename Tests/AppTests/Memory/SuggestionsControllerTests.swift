@testable import App
import Testing

/// HER-37 — scaffold-level guarantees for the suggestions stub. Locks in
/// the contract iOS depends on (non-empty list, no blank entries) until
/// HER-37a wires per-user generation.
@Suite
struct SuggestionsControllerTests {
    @Test
    func defaultsAreNonEmpty() {
        #expect(!SuggestionsController.defaults.isEmpty)
    }

    @Test
    func defaultsAreAllNonBlank() {
        for suggestion in SuggestionsController.defaults {
            #expect(!suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
