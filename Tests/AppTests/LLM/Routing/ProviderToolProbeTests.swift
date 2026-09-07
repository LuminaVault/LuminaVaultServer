@testable import App
import Foundation
import Testing

/// A credential that authenticates is not the same as an endpoint that works.
///
/// An OpenAI-compatible gateway can accept a request carrying `tools`, ignore
/// the block, and answer from the model's own knowledge. The reply is a
/// well-formed 200 with plausible content, so nothing upstream notices — and
/// the product then reports that skills and workflows are running when no tool
/// was ever called.
struct ProviderToolProbeTests {
    private func completion(_ message: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": message]]])
    }

    @Test
    func `a tool call is support`() {
        let data = completion([
            "role": "assistant",
            "tool_calls": [[
                "id": "call_1",
                "type": "function",
                "function": ["name": "lookup_job_status", "arguments": "{\"id\":\"lv-abc\"}"],
            ]],
        ])
        #expect(ProviderToolProbe.verdict(from: data) == .supported)
    }

    /// Some gateways still emit the pre-`tool_calls` shape.
    @Test
    func `the legacy function_call shape is support`() {
        let data = completion([
            "role": "assistant",
            "function_call": ["name": "lookup_job_status", "arguments": "{}"],
        ])
        #expect(ProviderToolProbe.verdict(from: data) == .supported)
    }

    /// The failure this exists to catch: a confident prose answer to a
    /// question that cannot be answered without the tool.
    @Test
    func `prose instead of a tool call is not support`() {
        let data = completion([
            "role": "assistant",
            "content": "Job lv-abc completed successfully at 14:03.",
        ])
        #expect(ProviderToolProbe.verdict(from: data) == .notSupported)
    }

    /// A model narrating what it *would* call has still not called it.
    @Test
    func `mentioning the tool in prose is not support`() {
        let data = completion([
            "role": "assistant",
            "content": "I would call lookup_job_status with that id.",
        ])
        #expect(ProviderToolProbe.verdict(from: data) == .notSupported)
    }

    @Test
    func `an unreadable or empty response yields no verdict`() {
        #expect(ProviderToolProbe.verdict(from: Data()) == .unknown)
        #expect(ProviderToolProbe.verdict(from: Data("not json".utf8)) == .unknown)
        #expect(ProviderToolProbe.verdict(from: completion(["role": "assistant"])) == .unknown)
        #expect(ProviderToolProbe.verdict(from: completion(["role": "assistant", "content": "  "])) == .unknown)
    }

    // MARK: - How a verdict is read back

    /// Unknown must be permissive. The probe is best-effort against a third
    /// party, and treating "we could not tell" as "no tools" would disable
    /// working setups on a network blip — a worse failure than the one being
    /// detected.
    @Test
    func `an absent verdict permits tools`() {
        #expect(ProviderToolProbe.allowsTools(storedVerdict: nil))
    }

    @Test
    func `a stored verdict is honoured in both directions`() {
        #expect(ProviderToolProbe.allowsTools(storedVerdict: true))
        #expect(ProviderToolProbe.allowsTools(storedVerdict: false) == false)
    }

    // MARK: - The request

    /// The question must be unanswerable from training data, or a model that
    /// ignores tools could answer it correctly by accident and be scored as
    /// supporting them.
    @Test
    func `the probe binds one tool and asks something only it can answer`() {
        let nonce = ProviderToolProbe.nonce()
        let payload = ProviderToolProbe.payload(model: "gpt-4o-mini", nonce: nonce)
        let tools = payload["tools"] as? [[String: Any]]
        #expect(tools?.count == 1)
        let messages = payload["messages"] as? [[String: Any]]
        let content = messages?.first?["content"] as? String ?? ""
        #expect(content.contains(nonce))
        // Runs against the user's own key, so it must cost near nothing.
        #expect((payload["max_tokens"] as? Int ?? .max) <= 64)
    }

    @Test
    func `each probe uses a fresh nonce`() {
        #expect(ProviderToolProbe.nonce() != ProviderToolProbe.nonce())
    }
}
