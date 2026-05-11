@testable import App
import Testing

/// HER-176: pure-function tests for the CN-origin classifier + filter
/// that `ModelRouter` (HER-161) will call. No DB, no HTTP.
struct ModelOriginTests {
    @Test
    func `classifies known CN origin model identifiers`() {
        for id in [
            "deepseek-r1",
            "DeepSeek-V3",
            "together_ai/deepseek-ai/DeepSeek-V3",
            "qwen2.5-72b-instruct",
            "Qwen/Qwen3-Coder",
            "moonshot-v1-8k",
            "kimi-k2",
            "01-ai/yi-large",
        ] {
            #expect(ModelOriginRegistry.isCNOrigin(id) == true, "expected CN: \(id)")
        }
    }

    @Test
    func `does not flag US or EU origin models`() {
        for id in [
            "gpt-5-mini",
            "gpt-4o",
            "gemini-2.5-flash",
            "claude-opus-4-7",
            "claude-haiku-4-5-20251001",
            "mistral-large-latest", // EU
            "llama-3.3-70b-versatile",
        ] {
            #expect(ModelOriginRegistry.isCNOrigin(id) == false, "expected non-CN: \(id)")
        }
    }

    @Test
    func `filter is no op when toggle off`() {
        let candidates = ["gpt-5-mini", "deepseek-r1", "qwen2.5-72b"]
        let kept = ModelOriginRegistry.filter(candidates, privacyNoCNOrigin: false)
        #expect(kept == candidates)
    }

    @Test
    func `filter excludes CN origin when toggle on`() {
        let candidates = ["gpt-5-mini", "deepseek-r1", "qwen2.5-72b", "gemini-2.5-flash", "kimi-k2"]
        let kept = ModelOriginRegistry.filter(candidates, privacyNoCNOrigin: true)
        #expect(kept == ["gpt-5-mini", "gemini-2.5-flash"])
    }

    @Test
    func `filter on empty candidates returns empty`() {
        let kept = ModelOriginRegistry.filter([String](), privacyNoCNOrigin: true)
        #expect(kept.isEmpty)
    }
}
