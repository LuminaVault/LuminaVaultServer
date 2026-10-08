import Foundation

/// How a request is being paid for, which changes how it is shaped.
struct AnthropicRequestOptions {
    /// The platform key is being spent and the managed trial is configured.
    var managed = false
    var trial: AnthropicManagedTrialConfig?
}

/// An Anthropic Messages request body plus what the response side needs.
struct AnthropicTranslatedRequest {
    let body: [String: Any]
    let model: String
    /// `response_format: json_object` was emulated with a system instruction,
    /// so the reply may still arrive wrapped in a Markdown fence.
    let stripJSONFences: Bool
}

struct AnthropicTranslatedResponse {
    let openAI: [String: Any]
    let usage: AnthropicUsage?
}

/// Token usage as Anthropic reports it.
struct AnthropicUsage: Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadInputTokens = 0
    var cacheCreationInputTokens = 0

    /// Everything the prompt cost, cached or not — what OpenAI's
    /// `prompt_tokens` means, and what the meters downstream expect.
    var promptTokens: Int {
        inputTokens + cacheReadInputTokens + cacheCreationInputTokens
    }

    /// Haiku trial rate card: $0.10 / $0.50 per MTok for prompts of 100K
    /// tokens or fewer, 5× above. An estimate for the `anthropic_usage` log
    /// line, not an invoice — cache reads and writes are priced as input.
    var estimatedCostUsdMicros: Int64 {
        let multiplier: Int64 = promptTokens > 100_000 ? 5 : 1
        return (Int64(promptTokens) * 100_000 + Int64(outputTokens) * 500_000) * multiplier / 1_000_000
    }

    /// Overwrite the counters present in `json`. `message_delta` repeats some
    /// of `message_start`'s fields with cumulative values, so last write wins.
    mutating func merge(_ json: [String: Any]?) {
        guard let json else { return }
        if let value = json["input_tokens"] as? Int {
            inputTokens = value
        }
        if let value = json["output_tokens"] as? Int {
            outputTokens = value
        }
        if let value = json["cache_read_input_tokens"] as? Int {
            cacheReadInputTokens = value
        }
        if let value = json["cache_creation_input_tokens"] as? Int {
            cacheCreationInputTokens = value
        }
    }
}

/// Per-stream state carried across SSE records.
struct AnthropicStreamState {
    var usage = AnthropicUsage()
    var model = ""
    var emittedText = false
}

extension AnthropicAdapter {
    /// Model used when a non-managed request names none.
    static let defaultModel = "claude-sonnet-4-6"
    /// Anthropic requires `max_tokens`; OpenAI treats it optional.
    static let defaultMaxTokens = 4096
    /// Thinking counts toward `max_tokens`; below this it is switched off.
    static let thinkingMinimumMaxTokens = 1024
    static let jsonOnlyInstruction = "Respond with a single JSON object, no code fences."
    /// Sent as a user turn when the transcript would otherwise end on the
    /// assistant: current models reject assistant prefill.
    static let continuePrompt = "Continue."
    static let imageMediaTypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]

    struct Turn {
        var role: String
        var blocks: [[String: Any]]
    }

    // MARK: - Request

    /// Translate an OpenAI chat-completions payload into an Anthropic
    /// Messages v1 request body. Shared by the buffered and streaming
    /// paths so request shaping stays in one place.
    ///
    /// - System/developer messages → top-level `system`.
    /// - String or array content; `image_url` data URIs → base64 image
    ///   blocks, http(s) URLs → URL image blocks. Any other part type throws
    ///   `.transient` so the router moves on to a provider that takes it.
    /// - `tools` → Anthropic tools; assistant `tool_calls` → `tool_use`;
    ///   `tool` messages → `tool_result` blocks merged into one user turn.
    /// - Consecutive same-role turns are merged, blank text is dropped, and
    ///   the transcript always ends on a user turn (no prefill).
    /// - `temperature`, `top_p` and `top_k` are never sent: Haiku 5.5 rejects
    ///   any non-default value.
    static func translateRequest(
        payload: Data,
        stream: Bool,
        options: AnthropicRequestOptions = AnthropicRequestOptions()
    ) throws -> AnthropicTranslatedRequest {
        guard
            let openAI = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let messages = openAI["messages"] as? [[String: Any]]
        else {
            throw ProviderError.permanent(
                provider: .anthropic,
                status: 400,
                body: "invalid OpenAI payload: cannot parse messages"
            )
        }

        let model = resolveModel(openAI["model"] as? String, options: options)
        let maxTokens = (openAI["max_tokens"] as? Int)
            ?? (openAI["max_completion_tokens"] as? Int)
            ?? defaultMaxTokens
        // Trial knobs (effort, thinking, structured output) only for the trial
        // model: older models a registry key can reach reject some of them.
        let trial = options.managed ? options.trial.flatMap { $0.model == model ? $0 : nil } : nil

        let transcript = try translateMessages(messages)
        let tools = translateTools(openAI["tools"])
        let turns = normalize(transcript.turns, toolsDeclared: !tools.isEmpty)

        var system = transcript.system
        var outputConfig: [String: Any] = [:]
        var stripJSONFences = false
        let responseFormat = openAI["response_format"] as? [String: Any]
        switch responseFormat?["type"] as? String {
        case "json_object":
            system.append(jsonOnlyInstruction)
            stripJSONFences = true
        case "json_schema":
            let schema = (responseFormat?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
            if trial != nil, let schema {
                outputConfig["format"] = ["type": "json_schema", "schema": schema]
            } else {
                system.append(jsonOnlyInstruction)
                stripJSONFences = true
            }
        default:
            break
        }

        var body: [String: Any] = [
            "model": model,
            "messages": turns.map { ["role": $0.role, "content": $0.blocks] },
            "max_tokens": maxTokens,
        ]
        if !system.isEmpty {
            body["system"] = system.joined(separator: "\n\n")
        }
        if !tools.isEmpty {
            body["tools"] = tools
            if let choice = translateToolChoice(openAI["tool_choice"]) {
                body["tool_choice"] = choice
            }
        }
        let stops = ((openAI["stop"] as? [String]) ?? (openAI["stop"] as? String).map { [$0] } ?? [])
            .filter { !isBlank($0) }
        if !stops.isEmpty {
            body["stop_sequences"] = stops
        }
        if let trial {
            // Thinking is adaptive by default. It must be off when the
            // transcript carries earlier tool turns — their thinking blocks
            // cannot survive the OpenAI-shaped transcript to be replayed — and
            // when `max_tokens` leaves no room for it.
            let disableThinking = transcript.hasToolTurns
                || trial.thinking == .disabled
                || maxTokens < thinkingMinimumMaxTokens
            var effort = trial.effort
            if disableThinking {
                body["thinking"] = ["type": "disabled"]
                // `disabled` is accepted only at effort `high` or below.
                if effort == "xhigh" || effort == "max" {
                    effort = "high"
                }
            }
            if let effort {
                outputConfig["effort"] = effort
            }
        }
        if !outputConfig.isEmpty {
            body["output_config"] = outputConfig
        }
        if stream {
            body["stream"] = true
        }
        return AnthropicTranslatedRequest(body: body, model: model, stripJSONFences: stripJSONFences)
    }

    /// Managed requests that name no Claude model — the router's slug for
    /// another provider, say — get the trial model; a non-Claude id would
    /// only 404. Everything else keeps the requested model.
    static func resolveModel(_ requested: String?, options: AnthropicRequestOptions) -> String {
        let model = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if options.managed, let trial = options.trial {
            return model.lowercased().hasPrefix("claude-") ? model : trial.model
        }
        return model.isEmpty ? defaultModel : model
    }

    static func translateMessages(_ messages: [[String: Any]]) throws -> (system: [String], turns: [Turn], hasToolTurns: Bool) {
        var system: [String] = []
        var turns: [Turn] = []
        var hasToolTurns = false
        // `tool_use` ids of the latest assistant turn not yet answered — pairs
        // tool messages that arrive without a `tool_call_id`.
        var unanswered: [String] = []

        func append(_ role: String, _ blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if let last = turns.indices.last, turns[last].role == role {
                turns[last].blocks += blocks
            } else {
                turns.append(Turn(role: role, blocks: blocks))
            }
        }

        for message in messages {
            let role = (message["role"] as? String)?.lowercased() ?? "user"
            switch role {
            case "system", "developer":
                let text = plainText(message["content"])
                if !isBlank(text) {
                    system.append(text)
                }
            case "assistant":
                var blocks = try contentBlocks(message["content"])
                if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                    hasToolTurns = true
                    unanswered = []
                    for call in calls {
                        let function = call["function"] as? [String: Any] ?? [:]
                        guard let name = function["name"] as? String, !name.isEmpty else { continue }
                        let id = (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                            ?? "toolu_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                        blocks.append([
                            "type": "tool_use",
                            "id": id,
                            "name": name,
                            "input": toolInput(function["arguments"]),
                        ])
                        unanswered.append(id)
                    }
                }
                append("assistant", blocks)
            case "tool", "function":
                hasToolTurns = true
                let explicit = (message["tool_call_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let id = explicit ?? unanswered.first ?? ""
                unanswered.removeAll { $0 == id }
                var block: [String: Any] = ["type": "tool_result", "tool_use_id": id]
                let text = plainText(message["content"])
                if !isBlank(text) {
                    block["content"] = text
                }
                append("user", [block])
            default:
                try append("user", contentBlocks(message["content"]))
            }
        }
        return (system, turns, hasToolTurns)
    }

    /// Make the transcript one the Messages API accepts.
    ///
    /// With tools declared, each assistant `tool_use` must be answered by a
    /// `tool_result` at the front of the very next user turn: unanswered calls
    /// get an error result, and results that answer nothing become text. With
    /// no tools declared (a final "answer now" call), tool blocks are rejected
    /// outright, so they are flattened to text.
    static func normalize(_ input: [Turn], toolsDeclared: Bool) -> [Turn] {
        var turns: [Turn] = []
        if toolsDeclared {
            for turn in input {
                guard turn.role == "user" else {
                    turns.append(turn)
                    continue
                }
                let expected = turns.last.map { $0.role == "assistant" ? toolUseIDs(in: $0) : [] } ?? []
                var results: [[String: Any]] = []
                var others: [[String: Any]] = []
                var answered: Set<String> = []
                for block in turn.blocks {
                    if block["type"] as? String == "tool_result" {
                        let id = block["tool_use_id"] as? String ?? ""
                        if expected.contains(id), !answered.contains(id) {
                            results.append(block)
                            answered.insert(id)
                        } else {
                            others.append(contentsOf: flattenToolBlock(block))
                        }
                    } else {
                        others.append(block)
                    }
                }
                for id in expected where !answered.contains(id) {
                    results.append(missingToolResult(id))
                }
                turns.append(Turn(role: "user", blocks: results + others))
            }
            if let last = turns.last, last.role == "assistant" {
                let pending = toolUseIDs(in: last)
                if !pending.isEmpty {
                    turns.append(Turn(role: "user", blocks: pending.map(missingToolResult)))
                }
            }
        } else {
            turns = input.map { Turn(role: $0.role, blocks: $0.blocks.flatMap(flattenToolBlock)) }
        }

        // Drop empty turns, merge what that makes adjacent, and bracket the
        // transcript with user turns.
        var merged: [Turn] = []
        for turn in turns where !turn.blocks.isEmpty {
            if let last = merged.indices.last, merged[last].role == turn.role {
                merged[last].blocks += turn.blocks
            } else {
                merged.append(turn)
            }
        }
        if merged.first?.role != "user" {
            merged.insert(Turn(role: "user", blocks: [textBlock(continuePrompt)]), at: 0)
        }
        if merged.last?.role != "user" {
            merged.append(Turn(role: "user", blocks: [textBlock(continuePrompt)]))
        }
        return merged
    }

    static func translateTools(_ value: Any?) -> [[String: Any]] {
        guard let tools = value as? [[String: Any]] else { return [] }
        return tools.compactMap { tool in
            guard
                (tool["type"] as? String ?? "function") == "function",
                let function = tool["function"] as? [String: Any],
                let name = function["name"] as? String, !name.isEmpty
            else { return nil }
            var schema = function["parameters"] as? [String: Any] ?? [:]
            if schema["type"] == nil {
                schema["type"] = "object"
            }
            var translated: [String: Any] = ["name": name, "input_schema": schema]
            if let description = function["description"] as? String, !isBlank(description) {
                translated["description"] = description
            }
            return translated
        }
    }

    /// `auto` (or absent) is Anthropic's default and is omitted.
    static func translateToolChoice(_ value: Any?) -> [String: Any]? {
        if let choice = value as? String {
            switch choice {
            case "none": return ["type": "none"]
            case "required": return ["type": "any"]
            default: return nil
            }
        }
        if let choice = value as? [String: Any],
           let name = (choice["function"] as? [String: Any])?["name"] as? String
        {
            return ["type": "tool", "name": name]
        }
        return nil
    }

    private static func contentBlocks(_ content: Any?) throws -> [[String: Any]] {
        if let text = content as? String {
            return isBlank(text) ? [] : [textBlock(text)]
        }
        guard let parts = content as? [[String: Any]] else { return [] }
        var blocks: [[String: Any]] = []
        for part in parts {
            let type = part["type"] as? String ?? "text"
            switch type {
            case "text", "input_text":
                if let text = part["text"] as? String, !isBlank(text) {
                    blocks.append(textBlock(text))
                }
            case "image_url":
                try blocks.append(imageBlock(part["image_url"]))
            default:
                throw ProviderError.transient(
                    provider: .anthropic,
                    status: 0,
                    body: "unsupported content part type for anthropic: \(type)"
                )
            }
        }
        return blocks
    }

    private static func imageBlock(_ value: Any?) throws -> [String: Any] {
        let url = ((value as? [String: Any])?["url"] as? String) ?? (value as? String) ?? ""
        if url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") {
            let header = url[url.index(url.startIndex, offsetBy: 5) ..< comma]
            let mediaType = header.split(separator: ";").first.map { String($0).lowercased() } ?? ""
            let data = String(url[url.index(after: comma)...])
            if header.lowercased().contains(";base64"), imageMediaTypes.contains(mediaType), !data.isEmpty {
                return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data]]
            }
            throw ProviderError.transient(
                provider: .anthropic,
                status: 0,
                body: "unsupported image data URI for anthropic: \(mediaType)"
            )
        }
        if url.hasPrefix("https://") || url.hasPrefix("http://") {
            return ["type": "image", "source": ["type": "url", "url": url]]
        }
        throw ProviderError.transient(provider: .anthropic, status: 0, body: "unsupported image_url for anthropic")
    }

    /// OpenAI carries tool arguments as a JSON string; Anthropic wants an object.
    private static func toolInput(_ arguments: Any?) -> [String: Any] {
        if let object = arguments as? [String: Any] {
            return object
        }
        guard let raw = arguments as? String, !isBlank(raw) else { return [:] }
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return object
        }
        return ["arguments": raw]
    }

    private static func toolUseIDs(in turn: Turn) -> [String] {
        turn.blocks.compactMap { $0["type"] as? String == "tool_use" ? $0["id"] as? String : nil }
    }

    private static func missingToolResult(_ id: String) -> [String: Any] {
        ["type": "tool_result", "tool_use_id": id, "content": "No result was returned for this tool call.", "is_error": true]
    }

    private static func flattenToolBlock(_ block: [String: Any]) -> [[String: Any]] {
        switch block["type"] as? String {
        case "tool_use":
            let name = block["name"] as? String ?? "tool"
            let input = (block["input"] as? [String: Any]).flatMap(jsonString) ?? "{}"
            return [textBlock("[Called tool \(name) with input \(input)]")]
        case "tool_result":
            let content = block["content"] as? String ?? ""
            return [textBlock(isBlank(content) ? "[Tool result: (empty)]" : "[Tool result: \(content)]")]
        default:
            return [block]
        }
    }

    private static func plainText(_ content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func jsonString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Response

    /// Translate Anthropic `/v1/messages` response → OpenAI chat
    /// completions response shape. Mirrors the projection
    /// `GeminiContentsAdapter` does for Gemini.
    ///
    /// Blocks are read by type: `thinking` is ignored, `tool_use` becomes
    /// OpenAI `tool_calls`. A refusal, or a reply with neither text nor tool
    /// calls (thinking used the whole `max_tokens`, say), throws `.transient`
    /// so the router fails over instead of returning an empty answer.
    static func translateResponse(
        body: Data,
        model: String,
        stripJSONFences: Bool = false
    ) throws -> AnthropicTranslatedResponse {
        guard let anthropic = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ProviderError.transient(provider: .anthropic, status: 200, body: "unparseable anthropic response")
        }
        let stopReason = anthropic["stop_reason"] as? String
        if stopReason == "refusal" {
            throw ProviderError.transient(provider: .anthropic, status: 200, body: "anthropic refusal")
        }

        var text = ""
        var toolCalls: [[String: Any]] = []
        for block in anthropic["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                text += block["text"] as? String ?? ""
            case "tool_use":
                let input = block["input"] as? [String: Any] ?? [:]
                toolCalls.append([
                    "id": block["id"] as? String ?? "toolu_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                    "type": "function",
                    "function": [
                        "name": block["name"] as? String ?? "",
                        "arguments": jsonString(input) ?? "{}",
                    ],
                ])
            default:
                continue
            }
        }
        if stripJSONFences {
            text = stripCodeFences(text)
        }
        if isBlank(text), toolCalls.isEmpty {
            throw ProviderError.transient(
                provider: .anthropic,
                status: 200,
                body: "anthropic returned no text (stop_reason=\(stopReason ?? "none"))"
            )
        }

        var usage = AnthropicUsage()
        usage.merge(anthropic["usage"] as? [String: Any])
        var message: [String: Any] = ["role": "assistant", "content": text]
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls
        }
        let openAI: [String: Any] = [
            "id": anthropic["id"] as? String ?? UUID().uuidString,
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": openAIFinishReason(stopReason),
            ]],
            "usage": [
                "prompt_tokens": usage.promptTokens,
                "completion_tokens": usage.outputTokens,
                "total_tokens": usage.promptTokens + usage.outputTokens,
            ],
        ]
        return AnthropicTranslatedResponse(openAI: openAI, usage: usage)
    }

    static func openAIFinishReason(_ stopReason: String?) -> String {
        switch stopReason {
        case "max_tokens", "model_context_window_exceeded": "length"
        case "tool_use": "tool_calls"
        case "refusal": "content_filter"
        default: "stop"
        }
    }

    /// Remove a Markdown code fence around a JSON reply.
    static func stripCodeFences(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        if let newline = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[trimmed.index(after: newline)...])
        } else {
            trimmed = String(trimmed.dropFirst(3))
        }
        if trimmed.hasSuffix("```") {
            trimmed = String(trimmed.dropLast(3))
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Stream records

    /// Parse one Anthropic SSE record. Returns `true` on `message_stop`.
    static func processStreamRecord(_ record: String, yield: (ChatStreamChunk) -> Void) throws -> Bool {
        var state = AnthropicStreamState()
        return try processStreamRecord(record, state: &state, yield: yield)
    }

    /// Parse one Anthropic SSE record, accumulating usage into `state`.
    ///
    /// Only text deltas are forwarded — `thinking`, `signature` and tool-input
    /// deltas are dropped. A stream that reaches its stop reason without any
    /// text (a refusal, thinking that used the whole budget, a tool call this
    /// text-only stream cannot carry) throws `.transient` before anything was
    /// yielded, so the transport can still fail over.
    static func processStreamRecord(
        _ record: String,
        state: inout AnthropicStreamState,
        yield: (ChatStreamChunk) -> Void
    ) throws -> Bool {
        var eventName: String?
        for rawLine in record.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("event:") {
                eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard
                !payload.isEmpty,
                let data = payload.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // The event type rides both the `event:` line and the JSON
            // `type` field; prefer the line, fall back to the field.
            switch eventName ?? (obj["type"] as? String ?? "") {
            case "message_start":
                state.usage.merge((obj["message"] as? [String: Any])?["usage"] as? [String: Any])
            case "content_block_delta":
                guard let delta = obj["delta"] as? [String: Any] else { break }
                let deltaType = delta["type"] as? String
                if deltaType == nil || deltaType == "text_delta",
                   let text = delta["text"] as? String,
                   !text.isEmpty
                {
                    state.emittedText = true
                    yield(ChatStreamChunk(delta: text))
                }
            case "message_delta":
                state.usage.merge(obj["usage"] as? [String: Any])
                if let delta = obj["delta"] as? [String: Any],
                   let stop = delta["stop_reason"] as? String
                {
                    guard state.emittedText else {
                        throw ProviderError.transient(
                            provider: .anthropic,
                            status: 200,
                            body: stop == "refusal" ? "anthropic refusal" : "anthropic streamed no text (stop_reason=\(stop))"
                        )
                    }
                    yield(ChatStreamChunk(delta: "", finishReason: openAIFinishReason(stop)))
                }
            case "message_stop":
                return true
            case "error":
                let message = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "anthropic stream error"
                throw ProviderError.transient(provider: .anthropic, status: 0, body: message)
            default:
                break
            }
        }
        return false
    }
}
