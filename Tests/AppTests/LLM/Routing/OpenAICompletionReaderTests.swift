@testable import App
import Foundation
import Testing

/// One parser, two callers: `ProviderToolProbe` asks *whether* an endpoint
/// honours tools; `AgentTurnTrace` records *which* tools a real turn called.
///
/// They must agree. If the probe recognised a shape the trace did not, a
/// provider would be advertised as tool-capable while every one of its turns
/// looked toolless to the user — which is exactly the confusion the trace
/// exists to remove.
struct OpenAICompletionReaderTests {
    private func completion(_ message: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["choices": [["message": message]]])) ?? Data()
    }

    @Test
    func `tool call names come back in call order`() {
        let data = completion([
            "role": "assistant",
            "tool_calls": [
                ["type": "function", "function": ["name": "search_memory", "arguments": "{}"]],
                ["type": "function", "function": ["name": "read_vault_file", "arguments": "{}"]],
            ],
        ])
        #expect(OpenAICompletionReader.toolCallNames(from: data) == ["search_memory", "read_vault_file"])
    }

    @Test
    func `the legacy function_call shape yields one name`() {
        let data = completion([
            "role": "assistant",
            "function_call": ["name": "lookup_job_status", "arguments": "{}"],
        ])
        #expect(OpenAICompletionReader.toolCallNames(from: data) == ["lookup_job_status"])
    }

    /// A turn that genuinely called nothing. Distinct from an unreadable body:
    /// this is a real answer and must be recorded as such.
    @Test
    func `a prose answer has no tool names`() {
        let data = completion(["role": "assistant", "content": "Here is the summary."])
        #expect(OpenAICompletionReader.toolCallNames(from: data).isEmpty)
        #expect(OpenAICompletionReader.assistantMessage(from: data) != nil)
    }

    /// nil message means "we could not read this", which the trace stores as
    /// NULL rather than as an empty tool list.
    @Test
    func `an unreadable body has no assistant message`() {
        #expect(OpenAICompletionReader.assistantMessage(from: Data()) == nil)
        #expect(OpenAICompletionReader.assistantMessage(from: Data("not json".utf8)) == nil)
        #expect(OpenAICompletionReader.assistantMessage(from: Data(#"{"choices":[]}"#.utf8)) == nil)
    }

    @Test
    func `malformed tool call entries are skipped rather than faked`() {
        let data = completion([
            "role": "assistant",
            "tool_calls": [
                ["type": "function", "function": ["arguments": "{}"]],
                ["type": "function", "function": ["name": "", "arguments": "{}"]],
                ["type": "function", "function": ["name": "real_tool", "arguments": "{}"]],
            ],
        ])
        #expect(OpenAICompletionReader.toolCallNames(from: data) == ["real_tool"])
    }

    /// The probe and the trace must not disagree about what a tool call is.
    @Test
    func `the probe agrees with the reader on every shape`() {
        let withTools = completion([
            "role": "assistant",
            "tool_calls": [["type": "function", "function": ["name": "t", "arguments": "{}"]]],
        ])
        let withProse = completion(["role": "assistant", "content": "no tools here"])
        #expect(ProviderToolProbe.verdict(from: withTools) == .supported)
        #expect(OpenAICompletionReader.toolCallNames(from: withTools).isEmpty == false)
        #expect(ProviderToolProbe.verdict(from: withProse) == .notSupported)
        #expect(OpenAICompletionReader.toolCallNames(from: withProse).isEmpty)
    }
}
