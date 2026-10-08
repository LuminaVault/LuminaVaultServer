@testable import App
import Foundation
import Logging
import LuminaVaultShared
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The OpenAI → Anthropic Messages translation the Haiku trial depends on.
///
/// Haiku 5.5 rejects non-default sampling parameters and assistant prefill,
/// thinks by default (and counts it toward `max_tokens`), and signals a refusal
/// as a 200. Each of those used to reach the wire unchanged — the adapter always
/// sent `temperature: 0.4`, dropped tool turns and read the first block as the
/// answer — so these pin the shape the trial needs.
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct AnthropicAdapterTranslationTests {
    private static let trial = AnthropicManagedTrialConfig(apiKey: "trial-key", effort: "low")
    private static let managed = AnthropicRequestOptions(managed: true, trial: trial)

    private static func payload(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private static func translate(
        _ object: [String: Any],
        options: AnthropicRequestOptions = managed,
        stream: Bool = false
    ) throws -> AnthropicTranslatedRequest {
        try AnthropicAdapter.translateRequest(payload: payload(object), stream: stream, options: options)
    }

    private static func isTransient(_ error: ProviderError) -> Bool {
        if case .transient = error {
            return true
        }
        return false
    }

    private static func messages(_ body: [String: Any]) -> [[String: Any]] {
        body["messages"] as? [[String: Any]] ?? []
    }

    private static func blocks(_ turn: [String: Any]) -> [[String: Any]] {
        turn["content"] as? [[String: Any]] ?? []
    }

    // MARK: - Sampling, system, model

    @Test
    func `sampling parameters are never sent`() throws {
        let request = try Self.translate([
            "model": "claude-haiku-5-5",
            "temperature": 0.7,
            "top_p": 0.9,
            "top_k": 40,
            "messages": [["role": "user", "content": "hi"]],
        ])
        #expect(request.body["temperature"] == nil)
        #expect(request.body["top_p"] == nil)
        #expect(request.body["top_k"] == nil)
    }

    @Test
    func `byok requests carry no temperature either`() throws {
        let request = try Self.translate(
            ["model": "claude-sonnet-4-6", "messages": [["role": "user", "content": "hi"]]],
            options: AnthropicRequestOptions()
        )
        #expect(request.body["temperature"] == nil)
    }

    @Test
    func `system messages become the top-level system field`() throws {
        let request = try Self.translate([
            "messages": [
                ["role": "system", "content": "Be brief."],
                ["role": "user", "content": "hi"],
                ["role": "system", "content": [["type": "text", "text": "Be kind."]]],
            ],
        ])
        #expect(request.body["system"] as? String == "Be brief.\n\nBe kind.")
        #expect(Self.messages(request.body).allSatisfy { $0["role"] as? String != "system" })
    }

    @Test
    func `managed requests without a claude model use the trial model`() throws {
        let request = try Self.translate(["model": "deepseek/deepseek-v4-flash", "messages": [["role": "user", "content": "hi"]]])
        #expect(request.model == "claude-haiku-5-5")
        #expect(request.body["model"] as? String == "claude-haiku-5-5")
    }

    @Test
    func `byok keeps the requested model and the old default`() throws {
        let named = try Self.translate(
            ["model": "claude-opus-4-7", "messages": [["role": "user", "content": "hi"]]],
            options: AnthropicRequestOptions()
        )
        #expect(named.model == "claude-opus-4-7")
        let unnamed = try Self.translate(
            ["messages": [["role": "user", "content": "hi"]]],
            options: AnthropicRequestOptions()
        )
        #expect(unnamed.model == AnthropicAdapter.defaultModel)
    }

    // MARK: - Content

    @Test
    func `array content maps text parts and data URI images`() throws {
        let request = try Self.translate([
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "What is this?"],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,iVBORw0KGgo="]],
                    ["type": "text", "text": "   "],
                ],
            ]],
        ])
        let turn = try #require(Self.messages(request.body).first)
        let blocks = Self.blocks(turn)
        #expect(blocks.count == 2, "blank text is dropped")
        #expect(blocks[0]["text"] as? String == "What is this?")
        let source = try #require(blocks[1]["source"] as? [String: Any])
        #expect(blocks[1]["type"] as? String == "image")
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == "iVBORw0KGgo=")
    }

    @Test
    func `an unsupported content part fails over`() throws {
        let error = #expect(throws: ProviderError.self) {
            try Self.translate([
                "messages": [["role": "user", "content": [["type": "input_audio", "input_audio": ["data": "AAA"]]]]],
            ])
        }
        #expect(error.map(Self.isTransient) == true)
    }

    // MARK: - Turns

    @Test
    func `consecutive same-role turns merge and the transcript ends on a user turn`() throws {
        let request = try Self.translate([
            "messages": [
                ["role": "user", "content": "one"],
                ["role": "user", "content": "two"],
                ["role": "assistant", "content": "Sure"],
            ],
        ])
        let turns = Self.messages(request.body)
        #expect(turns.map { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(Self.blocks(turns[0]).compactMap { $0["text"] as? String } == ["one", "two"])
        #expect(Self.blocks(turns[2]).first?["text"] as? String == AnthropicAdapter.continuePrompt)
    }

    @Test
    func `tools translate and tool turns become tool_use and merged tool_result`() throws {
        let request = try Self.translate([
            "tools": [[
                "type": "function",
                "function": [
                    "name": "search_vault",
                    "description": "Search notes",
                    "parameters": ["type": "object", "properties": ["q": ["type": "string"]]],
                ],
            ]],
            "tool_choice": "auto",
            "messages": [
                ["role": "user", "content": "find cats and dogs"],
                [
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": [
                        ["id": "call_1", "type": "function", "function": ["name": "search_vault", "arguments": "{\"q\":\"cats\"}"]],
                        ["id": "call_2", "type": "function", "function": ["name": "search_vault", "arguments": "{\"q\":\"dogs\"}"]],
                    ],
                ],
                ["role": "tool", "tool_call_id": "call_1", "content": "3 cat notes"],
                ["role": "tool", "tool_call_id": "call_2", "content": "1 dog note"],
            ],
        ])
        let tools = try #require(request.body["tools"] as? [[String: Any]])
        #expect(tools.first?["name"] as? String == "search_vault")
        #expect((tools.first?["input_schema"] as? [String: Any])?["type"] as? String == "object")
        #expect(request.body["tool_choice"] == nil, "auto is Anthropic's default")

        let turns = Self.messages(request.body)
        #expect(turns.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let toolUses = Self.blocks(turns[1])
        #expect(toolUses.map { $0["type"] as? String } == ["tool_use", "tool_use"])
        #expect(toolUses[0]["id"] as? String == "call_1")
        #expect((toolUses[0]["input"] as? [String: Any])?["q"] as? String == "cats")
        let results = Self.blocks(turns[2])
        #expect(results.map { $0["type"] as? String } == ["tool_result", "tool_result"])
        #expect(results.map { $0["tool_use_id"] as? String } == ["call_1", "call_2"])
        #expect(results[1]["content"] as? String == "1 dog note")
    }

    @Test
    func `an unanswered tool call gets an error result`() throws {
        let request = try Self.translate([
            "tools": [["type": "function", "function": ["name": "lookup"]]],
            "messages": [
                ["role": "user", "content": "go"],
                ["role": "assistant", "tool_calls": [["id": "call_9", "type": "function", "function": ["name": "lookup", "arguments": ""]]]],
            ],
        ])
        let turns = Self.messages(request.body)
        let last = try #require(turns.last)
        #expect(last["role"] as? String == "user")
        let result = try #require(Self.blocks(last).first)
        #expect(result["type"] as? String == "tool_result")
        #expect(result["tool_use_id"] as? String == "call_9")
        #expect(result["is_error"] as? Bool == true)
    }

    @Test
    func `tool turns flatten to text when the request declares no tools`() throws {
        let request = try Self.translate([
            "messages": [
                ["role": "user", "content": "go"],
                ["role": "assistant", "tool_calls": [["id": "call_1", "type": "function", "function": ["name": "lookup", "arguments": "{}"]]]],
                ["role": "tool", "tool_call_id": "call_1", "content": "found it"],
                ["role": "user", "content": "now answer"],
            ],
        ])
        let types = Self.messages(request.body).flatMap(Self.blocks).compactMap { $0["type"] as? String }
        #expect(!types.contains("tool_use"))
        #expect(!types.contains("tool_result"))
        #expect(request.body["tools"] == nil)
    }

    // MARK: - Thinking and effort

    @Test
    func `adaptive thinking is left to the default and effort is sent`() throws {
        let request = try Self.translate(["max_tokens": 4096, "messages": [["role": "user", "content": "hi"]]])
        #expect(request.body["thinking"] == nil)
        #expect((request.body["output_config"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test
    func `thinking is disabled when the transcript carries tool turns`() throws {
        let request = try Self.translate([
            "tools": [["type": "function", "function": ["name": "lookup"]]],
            "messages": [
                ["role": "user", "content": "go"],
                ["role": "assistant", "tool_calls": [["id": "c", "type": "function", "function": ["name": "lookup", "arguments": "{}"]]]],
                ["role": "tool", "tool_call_id": "c", "content": "ok"],
            ],
        ])
        #expect((request.body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
    }

    @Test
    func `thinking is disabled under 1024 max tokens`() throws {
        let request = try Self.translate(["max_tokens": 200, "messages": [["role": "user", "content": "classify"]]])
        #expect((request.body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
    }

    @Test
    func `ANTHROPIC_THINKING=disabled turns it off and clamps effort to high`() throws {
        let trial = AnthropicManagedTrialConfig(apiKey: "k", effort: "max", thinking: .disabled)
        let request = try Self.translate(
            ["messages": [["role": "user", "content": "hi"]]],
            options: AnthropicRequestOptions(managed: true, trial: trial)
        )
        #expect((request.body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect((request.body["output_config"] as? [String: Any])?["effort"] as? String == "high")
    }

    @Test
    func `byok requests never get trial thinking or effort`() throws {
        let request = try Self.translate(
            ["model": "claude-opus-5-5", "max_tokens": 100, "messages": [["role": "user", "content": "hi"]]],
            options: AnthropicRequestOptions()
        )
        #expect(request.body["thinking"] == nil)
        #expect(request.body["output_config"] == nil)
    }

    // MARK: - JSON output

    @Test
    func `json_object adds a system line and strips fences from the reply`() throws {
        let request = try Self.translate([
            "response_format": ["type": "json_object"],
            "messages": [["role": "system", "content": "Extract."], ["role": "user", "content": "x"]],
        ])
        #expect(request.stripJSONFences)
        #expect((request.body["system"] as? String)?.hasSuffix(AnthropicAdapter.jsonOnlyInstruction) == true)

        let reply = try Self.payload([
            "id": "msg_1",
            "stop_reason": "end_turn",
            "content": [["type": "text", "text": "```json\n{\"a\":1}\n```"]],
            "usage": ["input_tokens": 10, "output_tokens": 5],
        ])
        let response = try AnthropicAdapter.translateResponse(body: reply, model: request.model, stripJSONFences: true)
        #expect(Self.content(response) == "{\"a\":1}")
    }

    @Test
    func `json_schema becomes output_config format on the managed trial`() throws {
        let schema: [String: Any] = ["type": "object", "properties": ["a": ["type": "integer"]], "required": ["a"], "additionalProperties": false]
        let request = try Self.translate([
            "response_format": ["type": "json_schema", "json_schema": ["name": "out", "schema": schema]],
            "messages": [["role": "user", "content": "x"]],
        ])
        let format = try #require((request.body["output_config"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect((format["schema"] as? [String: Any])?["type"] as? String == "object")
        #expect(!request.stripJSONFences)
    }

    // MARK: - Response

    private static func content(_ response: AnthropicTranslatedResponse) -> String? {
        let choices = response.openAI["choices"] as? [[String: Any]]
        return (choices?.first?["message"] as? [String: Any])?["content"] as? String
    }

    private static func finishReason(_ response: AnthropicTranslatedResponse) -> String? {
        (response.openAI["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String
    }

    @Test
    func `response blocks are read by type and tool_use becomes tool_calls`() throws {
        let body = try Self.payload([
            "id": "msg_2",
            "stop_reason": "tool_use",
            "content": [
                ["type": "thinking", "thinking": "", "signature": "sig"],
                ["type": "text", "text": "Let me look."],
                ["type": "tool_use", "id": "toolu_1", "name": "search_vault", "input": ["q": "cats"]],
            ],
            "usage": ["input_tokens": 100, "output_tokens": 20, "cache_read_input_tokens": 30, "cache_creation_input_tokens": 5],
        ])
        let response = try AnthropicAdapter.translateResponse(body: body, model: "claude-haiku-5-5")
        #expect(Self.content(response) == "Let me look.")
        #expect(Self.finishReason(response) == "tool_calls")
        let message = try #require((response.openAI["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        let call = try #require((message["tool_calls"] as? [[String: Any]])?.first)
        #expect(call["id"] as? String == "toolu_1")
        let function = try #require(call["function"] as? [String: Any])
        #expect(function["name"] as? String == "search_vault")
        #expect(function["arguments"] as? String == "{\"q\":\"cats\"}")
        let usage = try #require(response.openAI["usage"] as? [String: Any])
        #expect(usage["prompt_tokens"] as? Int == 135, "cache read and creation count as prompt")
        #expect(usage["completion_tokens"] as? Int == 20)
    }

    @Test
    func `max_tokens maps to length`() throws {
        let body = try Self.payload(["stop_reason": "max_tokens", "content": [["type": "text", "text": "partial"]]])
        let response = try AnthropicAdapter.translateResponse(body: body, model: "m")
        #expect(Self.finishReason(response) == "length")
    }

    @Test
    func `a refusal fails over`() throws {
        let body = try Self.payload(["stop_reason": "refusal", "content": [["type": "text", "text": "I can't help"]]])
        #expect(throws: ProviderError.self) {
            try AnthropicAdapter.translateResponse(body: body, model: "m")
        }
    }

    @Test
    func `thinking that used the whole budget fails over`() throws {
        let body = try Self.payload([
            "stop_reason": "max_tokens",
            "content": [["type": "thinking", "thinking": "", "signature": "sig"]],
        ])
        let error = #expect(throws: ProviderError.self) {
            try AnthropicAdapter.translateResponse(body: body, model: "m")
        }
        #expect(error.map(Self.isTransient) == true)
    }

    // MARK: - Streaming

    private static func run(_ records: [String]) throws -> (chunks: [ChatStreamChunk], state: AnthropicStreamState) {
        var state = AnthropicStreamState()
        var chunks: [ChatStreamChunk] = []
        for record in records {
            _ = try AnthropicAdapter.processStreamRecord(record, state: &state) { chunks.append($0) }
        }
        return (chunks, state)
    }

    private static func record(_ event: String, _ json: String) -> String {
        "event: \(event)\ndata: \(json)"
    }

    @Test
    func `stream skips thinking deltas, maps the stop reason and accumulates usage`() throws {
        let (chunks, state) = try Self.run([
            Self.record("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":1200,"output_tokens":1,"cache_read_input_tokens":300}}}"#),
            Self.record("content_block_delta", #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}"#),
            Self.record("content_block_delta", #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}"#),
            Self.record("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":42}}"#),
        ])
        #expect(chunks == [ChatStreamChunk(delta: "Hello"), ChatStreamChunk(delta: "", finishReason: "length")])
        #expect(state.usage.inputTokens == 1200)
        #expect(state.usage.cacheReadInputTokens == 300)
        #expect(state.usage.outputTokens == 42)
    }

    @Test
    func `a refusal before any text fails the stream over`() throws {
        let error = #expect(throws: ProviderError.self) {
            try Self.run([
                Self.record("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":10}}}"#),
                Self.record("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#),
            ])
        }
        #expect(error.map(Self.isTransient) == true)
    }

    // MARK: - Managed failover mapping

    @Test(arguments: [401, 402, 403])
    func `auth and billing statuses park the provider`(status: Int) {
        let error = AnthropicAdapter.managedFailure(status: status, body: Data("{}".utf8))
        guard case .creditExhausted = error else {
            Issue.record("expected creditExhausted for \(status), got \(error)")
            return
        }
    }

    @Test(arguments: ["You have reached your specified API usage limits.", "Your credit balance is too low."])
    func `a 400 naming the spend cap parks the provider`(message: String) {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"\#(message)"}}"#.utf8)
        guard case .creditExhausted = AnthropicAdapter.managedFailure(status: 400, body: body) else {
            Issue.record("expected creditExhausted")
            return
        }
    }

    @Test(arguments: [400, 404, 413, 429, 500, 529])
    func `every other failure is transient so the chain fails over`(status: Int) {
        let error = AnthropicAdapter.managedFailure(status: status, body: Data(#"{"error":{"message":"nope"}}"#.utf8))
        #expect(error.isRecoverable)
        guard case .transient = error else {
            Issue.record("expected transient for \(status), got \(error)")
            return
        }
    }

    @Test
    func `stream errors classified by the shared classifier are remapped`() {
        let permanent = ProviderErrorClassifier.classify(provider: .anthropic, status: 404, body: Data("not_found".utf8))
        #expect(!permanent.isRecoverable)
        #expect(AnthropicAdapter.remapManaged(permanent).isRecoverable)
    }

    // MARK: - Cost estimate and catalogue

    @Test
    func `usage estimate follows the haiku rate card`() {
        var small = AnthropicUsage()
        small.inputTokens = 1_000_000 / 20 // 50K prompt
        small.outputTokens = 10000
        #expect(small.estimatedCostUsdMicros == 5000 + 5000)

        var long = AnthropicUsage()
        long.inputTokens = 150_000
        long.outputTokens = 0
        #expect(long.estimatedCostUsdMicros == 15000 * 5)
    }

    @Test
    func `haiku is priced for the meters but not routable`() {
        let priced = RouterModelCatalog.pricing(provider: .anthropic, model: "claude-haiku-5-5")
        #expect(priced?.inputPerMillionUsdMicros == 100_000)
        #expect(priced?.outputPerMillionUsdMicros == 500_000)
        #expect(RouterModelCatalog.entry(provider: .anthropic, model: "claude-haiku-5-5") == nil)
        #expect(!RouterModelCatalog.entries.contains { $0.model == "claude-haiku-5-5" })
        #expect(RoutedLLMTransport.catalogCost(
            provider: .anthropic,
            model: "claude-haiku-5-5",
            tokensIn: 1_000_000,
            tokensOut: 1_000_000,
            cerberus: nil
        ) == 600_000)
    }
}

/// The adapter on the wire: which key it spends, what it sends, and how a
/// managed failure surfaces to `RoutedLLMTransport`.
///
/// `.serialized` because `URLProtocol` registration is process-global.
@Suite(.serialized, .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct AnthropicAdapterManagedDispatchTests {
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

        override static func canInit(with _: URLRequest) -> Bool {
            handler != nil
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            let (response, data) = handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// Thread-safe record of what reached the wire.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [(request: URLRequest, body: [String: Any])] = []

        func record(_ request: URLRequest) {
            let body = Self.body(of: request)
            lock.lock(); defer { lock.unlock() }
            requests.append((request, body))
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return requests.count
        }

        var isEmpty: Bool {
            lock.lock(); defer { lock.unlock() }
            return requests.isEmpty
        }

        var last: (request: URLRequest, body: [String: Any])? {
            lock.lock(); defer { lock.unlock() }
            return requests.last
        }

        /// `URLProtocol` sees the body as a stream, not `httpBody`.
        private static func body(of request: URLRequest) -> [String: Any] {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 {
                        break
                    }
                    data.append(buffer, count: read)
                }
            }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
    }

    private static let trial = AnthropicManagedTrialConfig(apiKey: "TRIAL-KEY", effort: "low")
    private static let payload = Data(#"{"model":"claude-haiku-5-5","temperature":0.4,"messages":[{"role":"user","content":"hi"}]}"#.utf8)

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    private static func install(_ capture: Capture, status: Int, body: String) {
        StubProtocol.handler = { request in
            capture.record(request)
            let url = request.url ?? URL(fileURLWithPath: "/")
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) ?? HTTPURLResponse()
            return (response, Data(body.utf8))
        }
    }

    private static func adapter(apiKey: String = "", trial: AnthropicManagedTrialConfig? = trial) -> AnthropicAdapter {
        AnthropicAdapter(apiKey: apiKey, session: session(), logger: Logger(label: "test.anthropic"), managedTrial: trial)
    }

    private static let okBody = #"{"id":"msg_1","stop_reason":"end_turn","content":[{"type":"text","text":"hello"}],"usage":{"input_tokens":5,"output_tokens":2}}"#

    @Test
    func `managed requests spend the trial key with the trial shape`() async throws {
        let capture = Capture()
        Self.install(capture, status: 200, body: Self.okBody)
        defer { StubProtocol.handler = nil }

        let data = try await LLMRoutingContext.withValues({ $0.credentialMode = .managed }) {
            try await Self.adapter().chatCompletions(payload: Self.payload, sessionKey: "k", sessionID: nil)
        }
        let sent = try #require(capture.last)
        #expect(sent.request.value(forHTTPHeaderField: "x-api-key") == "TRIAL-KEY")
        #expect(sent.body["model"] as? String == "claude-haiku-5-5")
        #expect(sent.body["temperature"] == nil)
        #expect((sent.body["output_config"] as? [String: Any])?["effort"] as? String == "low")
        let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((reply?["usage"] as? [String: Any])?["prompt_tokens"] as? Int == 5)
    }

    @Test
    func `an overloaded 529 on the managed path is transient`() async {
        let capture = Capture()
        Self.install(capture, status: 529, body: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        defer { StubProtocol.handler = nil }

        let error = await #expect(throws: ProviderError.self) {
            try await LLMRoutingContext.withValues({ $0.credentialMode = .managed }) {
                try await Self.adapter().chatCompletions(payload: Self.payload, sessionKey: "k", sessionID: nil)
            }
        }
        guard case let .transient(_, status, _) = error else {
            Issue.record("expected transient, got \(String(describing: error))")
            return
        }
        #expect(status == 529)
    }

    @Test
    func `a 400 without the trial keeps the shared classification`() async {
        let capture = Capture()
        Self.install(capture, status: 400, body: #"{"error":{"message":"bad"}}"#)
        defer { StubProtocol.handler = nil }

        let error = await #expect(throws: ProviderError.self) {
            try await LLMRoutingContext.withValues({ $0.credentialMode = .managed }) {
                try await Self.adapter(apiKey: "REGISTRY-KEY", trial: nil)
                    .chatCompletions(payload: Self.payload, sessionKey: "k", sessionID: nil)
            }
        }
        #expect(error?.isRecoverable == false)
    }

    /// Before the trial this adapter's platform key was empty, so a managed
    /// route naming another Claude model 401'd. The trial key must not start
    /// paying for those at Sonnet/Opus rates.
    @Test
    func `the trial key is never spent on another model`() async {
        let capture = Capture()
        Self.install(capture, status: 200, body: Self.okBody)
        defer { StubProtocol.handler = nil }

        let opus = Data(#"{"model":"claude-opus-4-7","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        let error = await #expect(throws: ProviderError.self) {
            try await LLMRoutingContext.withValues({ $0.credentialMode = .managed }) {
                try await Self.adapter().chatCompletions(payload: opus, sessionKey: "k", sessionID: nil)
            }
        }
        guard case let .permanent(_, status, _) = error else {
            Issue.record("expected permanent, got \(String(describing: error))")
            return
        }
        #expect(status == 401)
        #expect(capture.isEmpty, "nothing reached the wire")
    }

    @Test
    func `byok never spends the trial key`() async {
        let capture = Capture()
        Self.install(capture, status: 200, body: Self.okBody)
        defer { StubProtocol.handler = nil }

        await #expect(throws: BYOKKeysRequiredError.self) {
            try await LLMRoutingContext.withValues({ $0.credentialMode = .byok }) {
                try await Self.adapter().chatCompletions(payload: Self.payload, sessionKey: "k", sessionID: nil)
            }
        }
        #expect(capture.isEmpty)
    }

    /// End to end through the transport: the trial route fails with a status
    /// the shared classifier would call permanent, and the original pick still
    /// answers.
    @Test
    func `an anthropic failure hands the request to the original pick`() async throws {
        let capture = Capture()
        Self.install(capture, status: 404, body: #"{"type":"error","error":{"type":"not_found_error","message":"model: claude-haiku-5-5"}}"#)
        defer { StubProtocol.handler = nil }

        let fallback = RoutedLLMTransportFallbackTests.StubAdapter(kind: .openRouter, outcomes: [.success(Data("FALLBACK".utf8))])
        let registry = ProviderRegistry(adapters: [Self.adapter(), fallback], logger: Logger(label: "test"))
        // The shape `AnthropicManagedTrialRouter` produces: trial route first,
        // the original managed pick behind it.
        let decision = RouteDecision(
            primary: Self.trial.route,
            fallbacks: [ModelRoute(provider: .openRouter, modelID: "deepseek/deepseek-v4-flash")],
            credentialMode: .managed
        )
        let transport = RoutedLLMTransport(
            registry: registry,
            router: RoutedLLMTransportFallbackTests.FixedRouter(decision: decision),
            logger: Logger(label: "test")
        )

        let result = try await transport.chatCompletions(payload: Self.payload, sessionKey: "k", sessionID: nil)
        #expect(String(data: result, encoding: .utf8) == "FALLBACK")
        #expect(capture.count == 1, "anthropic was tried first")
    }
}
