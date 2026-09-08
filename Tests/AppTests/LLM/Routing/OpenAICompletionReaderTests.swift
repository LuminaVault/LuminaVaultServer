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

/// "3 tools, names unknown" is a real state, not a degenerate one.
///
/// The streaming chat path observes tool *invocations* — `ChatStreamChunk`
/// carries a `toolCallID` and never a name — so a chat turn can know that
/// three tools ran without knowing which. The record has to hold that without
/// collapsing it into "no tools", which is what a user would otherwise be
/// shown for every streamed turn.
struct AgentToolCallsShapeTests {
    @Test
    func `names imply a matching count`() {
        let record = AgentToolCalls(names: ["a", "b"])
        #expect(record.count == 2)
        #expect(record.names == ["a", "b"])
    }

    @Test
    func `a count can stand without names`() {
        let record = AgentToolCalls(count: 3)
        #expect(record.count == 3)
        #expect(record.names.isEmpty)
    }

    /// Never report fewer tools than we have names for.
    @Test
    func `a count is never below the number of names`() {
        #expect(AgentToolCalls(count: 0, names: ["a", "b"]).count == 2)
    }

    /// Rows written before `count` existed carry only names, and must decode.
    @Test
    func `a legacy record without a count infers it from names`() throws {
        let legacy = Data(#"{"names":["a","b","c"]}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentToolCalls.self, from: legacy)
        #expect(decoded.count == 3)
    }

    @Test
    func `an empty record means the turn ran without tools`() throws {
        let empty = Data(#"{"names":[],"count":0}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentToolCalls.self, from: empty)
        #expect(decoded.names.isEmpty)
        // An empty record's count agrees with its names, both saying "none ran".
        #expect(decoded.count == decoded.names.count)
    }

    /// nil only when we know nothing at all; an empty record is an answer.
    @Test
    func `the recorder distinguishes no-tools from no-information`() {
        #expect(AgentTurnTraceRecorder.toolRecord(names: nil, count: nil) == nil)
        #expect(AgentTurnTraceRecorder.toolRecord(names: [], count: nil)?.names.isEmpty == true)
        #expect(AgentTurnTraceRecorder.toolRecord(names: nil, count: 3)?.count == 3)
        #expect(AgentTurnTraceRecorder.toolRecord(names: ["a"], count: 9)?.names == ["a"])
    }
}
