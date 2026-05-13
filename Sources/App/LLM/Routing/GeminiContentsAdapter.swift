import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-199 — `ProviderAdapter` that translates an OpenAI chat-completions
/// payload into Google Gemini `generateContent` v1beta API shape, calls
/// the Gemini endpoint, and translates the response back to OpenAI shape.
///
/// Payload differences (OpenAI → Gemini):
/// - `messages[]` → `contents[]` with role: user|model (no system role)
/// - System messages → `system_instruction` (or folded into first user msg)
/// - `tools[]` → `tools[].function_declarations[]`
/// - `tool_calls[]` → Gemini `functionCall` part
/// - role: "tool" → Gemini `functionResponse` part
struct GeminiContentsAdapter: ProviderAdapter {
    let kind: ProviderKind = .gemini
    private let apiKey: String
    private let session: URLSession
    private let logger: Logger

    init(
        apiKey: String,
        session: URLSession = .shared,
        logger: Logger,
    ) {
        self.apiKey = apiKey
        self.session = session
        self.logger = logger
    }

    func chatCompletions(payload: Data, profileUsername: String) async throws -> Data {
        try await chatCompletionsWithMetadata(payload: payload, profileUsername: profileUsername).data
    }

    func chatCompletionsWithMetadata(
        payload: Data,
        profileUsername _: String,
    ) async throws -> HermesChatTransportMetadata {
        // 1. Parse the OpenAI payload
        guard
            var openAI = try? JSONSerialization.jsonObject(with: payload)
            as? [String: Any],
            let rawMessages = openAI["messages"] as? [[String: Any]]
        else {
            throw ProviderError.permanent(
                provider: kind,
                status: 400,
                body: "invalid OpenAI payload: cannot parse messages",
            )
        }

        // 2. Extract model name and resolve Gemini endpoint
        let rawModel = openAI["model"] as? String ?? ""
        let geminiModel = resolveGeminiModel(from: rawModel)
        let url = Self.makeURL(for: geminiModel, apiKey: apiKey)

        // 3. Translate messages → Gemini shape
        let translated = Self.translateToGemini(
            messages: rawMessages,
            tools: openAI["tools"] as? [[String: Any]],
            temperature: openAI["temperature"] as? Double,
            maxTokens: openAI["max_tokens"] as? Int,
            topP: openAI["top_p"] as? Double,
            stopSequences: openAI["stop"] as? [String],
        )

        // 4. Encode Gemini request body
        let geminiBody: Data
        do {
            geminiBody = try JSONSerialization.data(withJSONObject: translated)
        } catch {
            throw ProviderError.permanent(
                provider: kind,
                status: 400,
                body: "failed to encode Gemini request: \(error)",
            )
        }

        // 5. Make the HTTP call
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = geminiBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ProviderError.network(provider: kind, underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.transient(provider: kind, status: 0, body: nil)
        }

        let status = http.statusCode
        if (200 ..< 300).contains(status) {
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }

            // 6. Translate Gemini response → OpenAI shape
            let openAIResponse = Self.translateFromGemini(
                body: data,
                requestedModel: rawModel,
            )

            let responseData: Data
            do {
                responseData = try JSONSerialization.data(withJSONObject: openAIResponse)
            } catch {
                throw ProviderError.transient(
                    provider: kind,
                    status: status,
                    body: "failed to encode OpenAI response",
                )
            }

            return HermesChatTransportMetadata(data: responseData, headers: headers)
        }

        // 7. Error classification
        let preview = String(data: data.prefix(512), encoding: .utf8)
        if status == 429 || (500 ..< 600).contains(status) {
            logger.error("gemini upstream transient \(status): \(preview ?? "<binary>")")
            throw ProviderError.transient(provider: kind, status: status, body: preview)
        }
        logger.error("gemini upstream permanent \(status): \(preview ?? "<binary>")")
        throw ProviderError.permanent(provider: kind, status: status, body: preview)
    }

    // MARK: - Model Resolution

    private static func makeURL(for model: String, apiKey: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "generativelanguage.googleapis.com"
        components.path = "/v1beta/models/\(model):generateContent"
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            fatalError("invalid gemini url for model=\(model)")
        }
        return url
    }

    /// Resolve a user-facing model hint to a full Gemini API model name.
    /// Short aliases are expanded; unknown names pass through verbatim.
    private static func resolveGeminiModel(from raw: String) -> String {
        let lower = raw.lowercased()
        switch lower {
        case "gemini-2.5-pro", "gemini-pro", "gemini-pro-latest":
            return "gemini-2.5-pro"
        case "gemini-2.5-flash", "gemini-flash", "gemini-flash-latest":
            return "gemini-2.5-flash"
        default:
            // If it already starts with "gemini-" pass through
            if lower.hasPrefix("gemini-") { return raw }
            // Fallback to latest pro
            return "gemini-2.5-pro"
        }
    }

    private func resolveGeminiModel(from raw: String) -> String {
        Self.resolveGeminiModel(from: raw)
    }

    // MARK: - OpenAI → Gemini Translation

    private static func translateToGemini(
        messages: [[String: Any]],
        tools: [[String: Any]]? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        topP: Double? = nil,
        stopSequences: [String]? = nil,
    ) -> [String: Any] {
        var result: [String: Any] = [:]

        var contents: [[String: Any]] = []
        var systemContents: [[String: Any]] = []

        for msg in messages {
            guard let role = msg["role"] as? String else { continue }
            let parts = partsFromMessage(msg)

            switch role {
            case "system":
                // system_instruction — Gemini's native system prompt field
                systemContents = parts
            case "user":
                contents.append(["role": "user", "parts": parts])
            case "assistant" where partsContainToolCalls(parts):
                // Assistant message with tool_calls: emit as model role
                // with functionCall parts alongside text parts
                contents.append(["role": "model", "parts": parts])
            case "assistant":
                contents.append(["role": "model", "parts": parts])
            case "tool":
                // Tool response: wrap in functionResponse part
                // Gemini expects functionResponse in a user-role message
                let fnParts = buildFunctionResponseParts(from: msg)
                if !fnParts.isEmpty {
                    contents.append(["role": "user", "parts": fnParts])
                }
            default:
                // Unknown role — send as user to be safe
                contents.append(["role": "user", "parts": parts])
            }
        }

        // system_instruction
        if !systemContents.isEmpty {
            result["system_instruction"] = ["parts": systemContents]
        }

        // contents (the conversation history)
        if !contents.isEmpty {
            result["contents"] = contents
        }

        // tools → function_declarations
        if let tools, !tools.isEmpty {
            var geminiTools: [[String: Any]] = []
            for tool in tools {
                if let function = tool["function"] as? [String: Any] {
                    let declaration: [String: Any] = [
                        "name": function["name"] ?? "",
                        "description": function["description"] ?? "",
                        "parameters": function["parameters"] ?? [:],
                    ]
                    geminiTools.append(
                        ["function_declarations": [declaration]],
                    )
                }
            }
            if !geminiTools.isEmpty {
                result["tools"] = geminiTools
            }
        }

        // generation config
        var generationConfig: [String: Any] = [:]
        if let temperature { generationConfig["temperature"] = temperature }
        if let maxTokens { generationConfig["maxOutputTokens"] = maxTokens }
        if let topP { generationConfig["topP"] = topP }
        if let stopSequences { generationConfig["stopSequences"] = stopSequences }
        if !generationConfig.isEmpty {
            result["generationConfig"] = generationConfig
        }

        return result
    }

    /// Extract content and/or tool_calls as Gemini parts.
    private static func partsFromMessage(_ msg: [String: Any]) -> [[String: Any]] {
        var parts: [[String: Any]] = []

        // Text content
        if let text = msg["content"] as? String, !text.isEmpty {
            parts.append(["text": text])
        } else if msg["content"] == nil, msg["tool_calls"] != nil {
            // No content field but has tool_calls — Gemini expects at least
            // an empty text part alongside functionCall parts
            parts.append(["text": ""])
        }

        // tool_calls → functionCall parts
        if let toolCalls = msg["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                guard
                    let id = call["id"] as? String,
                    let function = call["function"] as? [String: Any],
                    let fnName = function["name"] as? String
                else { continue }

                var fnArgs: [String: Any] = [:]
                if let argsStr = function["arguments"] as? String,
                   let argsData = argsStr.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                {
                    fnArgs = parsed
                }

                let functionCall: [String: Any] = [
                    "name": fnName,
                    "args": fnArgs,
                    "_callId": id, // stored as metadata for round-trip
                ]
                parts.append(functionCall)
            }
        }

        return parts
    }

    private static func partsContainToolCalls(_ parts: [[String: Any]]) -> Bool {
        parts.contains { $0["name"] != nil && $0["args"] != nil }
    }

    /// Build functionResponse parts from a tool-result message.
    /// OpenAI: { role: "tool", name: "...", content: "..." }
    /// Gemini: { role: "user", parts: [{ functionResponse: { name, response }}}]}
    private static func buildFunctionResponseParts(from msg: [String: Any]) -> [[String: Any]] {
        guard let name = msg["name"] as? String else {
            return []
        }

        var contentResponse: [String: Any] = [:]
        if let text = msg["content"] as? String {
            contentResponse["content"] = text
        } else if let content = msg["content"] {
            contentResponse["content"] = content
        }

        // Try to parse content as JSON for rich response
        if let text = msg["content"] as? String,
           let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data)
        {
            contentResponse = json as? [String: Any] ?? contentResponse
        }

        let fnResponse: [String: Any] = [
            "functionResponse": [
                "name": name,
                "response": contentResponse,
            ],
        ]
        return [fnResponse]
    }

    // MARK: - Gemini → OpenAI Translation

    private static func translateFromGemini(
        body: Data,
        requestedModel: String,
    ) -> [String: Any] {
        guard
            let json = try? JSONSerialization.jsonObject(with: body)
            as? [String: Any]
        else {
            return fallbackErrorResponse(
                status: 502,
                message: "invalid gemini response body",
                model: requestedModel,
            )
        }

        var choices: [[String: Any]] = []

        if let candidates = json["candidates"] as? [[String: Any]] {
            for (index, candidate) in candidates.enumerated() {
                var choiceChoice: [String: Any] = [:]

                // finish_reason mapping
                let finishReasonRaw = candidate["finishReason"] as? String ?? "STOP"
                let openAIFinish = mapFinishReason(finishReasonRaw)
                choiceChoice["finish_reason"] = openAIFinish
                choiceChoice["index"] = index

                // Extract message content and tool calls from candidate
                var messageContent = ""
                var toolCalls: [[String: Any]] = []

                if let content = candidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]]
                {
                    for part in parts {
                        if let text = part["text"] as? String {
                            messageContent += text
                        } else if let fnCall = part["functionCall"] as? [String: Any] {
                            // Gemini functionCall → OpenAI tool_call
                            let name = fnCall["name"] as? String ?? ""
                            let args = fnCall["args"] as? [String: Any] ?? [:]
                            let callId = fnCall["_callId"] as? String
                                ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")

                            let argsStr: String = if let argsData = try? JSONSerialization.data(withJSONObject: args),
                                                     let s = String(data: argsData, encoding: .utf8)
                            {
                                s
                            } else {
                                "{}"
                            }

                            toolCalls.append([
                                "id": callId,
                                "type": "function",
                                "function": [
                                    "name": name,
                                    "arguments": argsStr,
                                ],
                            ])
                        }
                    }
                }

                // Safety rating annotation (append to content if blocked)
                if let finish = candidate["finishReason"] as? String,
                   finish == "SAFETY" || finish == "BLOCKLIST" || finish == "PROHIBITED_CONTENT"
                {
                    if let safetyRatings = candidate["safetyRatings"] as? [[String: Any]] {
                        let flags = safetyRatings.compactMap { rating -> String? in
                            guard let category = rating["category"] as? String,
                                  let blocked = rating["blocked"] as? Bool,
                                  blocked
                            else { return nil }
                            return category
                        }
                        if !flags.isEmpty {
                            messageContent += "\n[Blocked: \(flags.joined(separator: ", "))]"
                        }
                    }
                }

                var messageObj: [String: Any] = ["role": "assistant"]
                if !messageContent.isEmpty {
                    messageObj["content"] = messageContent
                } else if toolCalls.isEmpty {
                    // Gemini returned empty — might be a blank response
                    messageObj["content"] = ""
                }

                if !toolCalls.isEmpty {
                    messageObj["tool_calls"] = toolCalls
                    // OpenAI spec: when tool_calls present, content can be nil
                    if messageObj["content"] as? String == "" {
                        messageObj["content"] = nil
                    }
                }

                choiceChoice["message"] = messageObj
                choices.append(choiceChoice)
            }
        }

        // usage mapping
        var usageObj: [String: Any] = [:]
        if let usage = json["usageMetadata"] as? [String: Any] {
            if let promptTokens = usage["promptTokenCount"] {
                usageObj["prompt_tokens"] = promptTokens
            }
            if let candidatesTokens = usage["candidatesTokenCount"] {
                usageObj["completion_tokens"] = candidatesTokens
            }
            if let totalTokens = usage["totalTokenCount"] {
                usageObj["total_tokens"] = totalTokens
            }
        }

        let now = Int(Date().timeIntervalSince1970)
        return [
            "id": UUID().uuidString,
            "object": "chat.completion",
            "created": now,
            "model": requestedModel,
            "choices": choices,
            "usage": usageObj,
        ]
    }

    private static func mapFinishReason(_ geminiReason: String) -> String {
        switch geminiReason {
        case "STOP":
            "stop"
        case "MAX_TOKENS":
            "length"
        case "SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT":
            "content_filter"
        case "RECITATION":
            "content_filter"
        case "FINISH_REASON_UNSPECIFIED", "OTHER":
            "stop"
        default:
            "stop"
        }
    }

    private static func fallbackErrorResponse(
        status _: Int,
        message: String,
        model: String,
    ) -> [String: Any] {
        let now = Int(Date().timeIntervalSince1970)
        return [
            "id": UUID().uuidString,
            "object": "chat.completion",
            "created": now,
            "model": model,
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": "Error: \(message)",
                    ],
                    "finish_reason": "stop",
                ],
            ],
            "usage": [
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0,
            ],
        ]
    }
}
