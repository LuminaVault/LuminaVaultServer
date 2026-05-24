@testable import App
import Testing

/// HER-37 — pure unit tests for the path-stem → title derivation used by
/// `GET /v1/memos`. Title rendering should turn the on-disk filename into
/// something human-readable for the "Lumina's Notebook" list. Full
/// HTTP-level coverage lives in a follow-up E2E suite.
struct MemoControllerTitleTests {
    @Test
    func `titlecases slug segments`() {
        let title = MemoController.titleFromPath("memos/2026-05-17/sleep-patterns.md")
        #expect(title == "Sleep Patterns")
    }

    @Test
    func `drops markdown extension`() {
        let title = MemoController.titleFromPath("memos/2026-05-17/quick-thoughts.md")
        #expect(title == "Quick Thoughts")
    }

    @Test
    func `single word slug stays single word`() {
        let title = MemoController.titleFromPath("memos/2026-05-17/sleep.md")
        #expect(title == "Sleep")
    }

    @Test
    func `handles paths without date segment`() {
        let title = MemoController.titleFromPath("memos/foo-bar-baz.md")
        #expect(title == "Foo Bar Baz")
    }
}
