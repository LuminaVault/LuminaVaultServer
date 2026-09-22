@testable import App
import Foundation
import Testing

/// `withStreamFlag` is how every streaming chat adapter asks its upstream to
/// stream. It moved out of the transport and into the adapters when native
/// streaming was folded into `ProviderAdapter.chatStream`, and nothing tested
/// it once the transport-level assertion stopped applying. If it silently
/// stopped setting the flag, BYOK replies would arrive as one buffered block
/// with every other test still green.
@Suite
struct ProviderStreamKitStreamFlagTests {
    @Test
    func `adds stream true and keeps every other field`() async throws {
        let original: [String: Any] = [
            "model": "gpt-stream",
            "temperature": 0.2,
            "messages": [["role": "user", "content": "Hello"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: original)
        let flagged = ProviderStreamKit.withStreamFlag(data)
        let dict = try #require(try JSONSerialization.jsonObject(with: flagged) as? [String: Any])

        #expect(dict["stream"] as? Bool == true)
        #expect(dict["model"] as? String == "gpt-stream")
        #expect(dict["temperature"] as? Double == 0.2)
        #expect((dict["messages"] as? [[String: Any]])?.first?["content"] as? String == "Hello")
    }

    @Test
    func `overrides an explicit stream false`() async throws {
        let data = try JSONSerialization.data(withJSONObject: ["model": "m", "stream": false])
        let dict = try #require(
            try JSONSerialization.jsonObject(with: ProviderStreamKit.withStreamFlag(data)) as? [String: Any]
        )
        #expect(dict["stream"] as? Bool == true)
    }

    @Test
    func `leaves a payload it cannot parse untouched`() async throws {
        let garbage = Data("not json".utf8)
        #expect(ProviderStreamKit.withStreamFlag(garbage) == garbage)
    }
}
