@testable import App
import Foundation
import Testing

/// P2 — SSE/NDJSON record parsing for native provider streaming.
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct ProviderStreamKitTests {
    private func collect(_ record: String) throws -> (chunks: [ChatStreamChunk], done: Bool) {
        var chunks: [ChatStreamChunk] = []
        let done = try ProviderStreamKit.processOpenAIRecord(record, kind: .openai) { chunks.append($0) }
        return (chunks, done)
    }

    @Test("OpenAI chunk yields content delta, no finish")
    func openAIContentDelta() throws {
        let (chunks, done) = try collect(#"data: {"choices":[{"delta":{"content":"Hel"}}]}"#)
        #expect(chunks == [ChatStreamChunk(delta: "Hel")])
        #expect(done == false)
    }

    @Test("OpenAI finish_reason yields terminal chunk and stops")
    func openAIFinish() throws {
        let (chunks, done) = try collect(#"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        #expect(chunks == [ChatStreamChunk(delta: "", finishReason: "stop")])
        #expect(done)
    }

    @Test("OpenAI [DONE] sentinel stops without a chunk")
    func openAIDone() throws {
        let (chunks, done) = try collect("data: [DONE]")
        #expect(chunks.isEmpty)
        #expect(done)
    }

    @Test("OpenAI inline error throws")
    func openAIInlineError() {
        #expect(throws: ProviderError.self) {
            _ = try collect(#"data: {"error":{"message":"rate limited"}}"#)
        }
    }

    @Test("named non-content event is ignored")
    func openAINonContentEvent() throws {
        let record = "event: hermes.tool.progress\ndata: {\"tool\":\"search\"}"
        let (chunks, done) = try collect(record)
        #expect(chunks.isEmpty)
        #expect(done == false)
    }

    @Test("withStreamFlag injects stream:true")
    func streamFlag() {
        let payload = #"{"model":"gpt-4o","messages":[]}"#.data(using: .utf8)!
        let flagged = ProviderStreamKit.withStreamFlag(payload)
        let obj = try? JSONSerialization.jsonObject(with: flagged) as? [String: Any]
        #expect(obj?["stream"] as? Bool == true)
    }

    @Test("Anthropic content_block_delta yields text")
    func anthropicDelta() throws {
        var chunks: [ChatStreamChunk] = []
        let record = "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}"
        let done = try AnthropicAdapter.processStreamRecord(record) { chunks.append($0) }
        #expect(chunks == [ChatStreamChunk(delta: "Hi")])
        #expect(done == false)
    }

    @Test("Anthropic message_stop ends the stream")
    func anthropicStop() throws {
        var chunks: [ChatStreamChunk] = []
        let done = try AnthropicAdapter.processStreamRecord("event: message_stop\ndata: {\"type\":\"message_stop\"}") { chunks.append($0) }
        #expect(chunks.isEmpty)
        #expect(done)
    }

    @Test("Gemini stream object extracts delta + finish")
    func geminiStreamObject() {
        let data = #"{"candidates":[{"content":{"parts":[{"text":"yo"}]},"finishReason":"STOP"}]}"#.data(using: .utf8)!
        let parsed = GeminiContentsAdapter.parseStreamObject(data)
        #expect(parsed?.delta == "yo")
        #expect(parsed?.finishReason == "STOP")
    }
}
