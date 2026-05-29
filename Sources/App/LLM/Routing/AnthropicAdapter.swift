import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-252 — `ProviderAdapter` that translates an OpenAI chat-completions
/// payload into Anthropic Messages v1 API shape, calls
/// `POST /v1/messages`, and translates the response back to OpenAI shape
/// so the rest of the server pipeline sees a uniform wire format.
///
/// Payload differences (OpenAI → Anthropic):
/// - `messages[role=system].content` → top-level `system` string
/// - `messages[role=user|assistant]` → kept; `tool` role not yet
///   translated (Anthropic uses a different `tool_use`/`tool_result`
///   shape; out of scope for HER-252).
/// - `max_tokens` is required by Anthropic — defaulted to 4096 if the
///   caller omits it.
///
/// Auth: `x-api-key: <key>` + `anthropic-version: 2023-06-01` (the
/// last stable Messages API version pinned in the public SDK).
struct AnthropicAdapter: ProviderAdapter {
    let kind: ProviderKind = .anthropic
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession
    private let logger: Logger
    private let userCredentials: UserCredentialStore?

    /// Anthropic API version pin. Bumping this requires a release-notes
    /// review of behavior changes (tool use, prompt caching, etc.).
    static let apiVersion = "2023-06-01"

    init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        session: URLSession = .shared,
        logger: Logger,
        userCredentials: UserCredentialStore? = nil,
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.logger = logger
        self.userCredentials = userCredentials
    }

    func chatCompletions(payload: Data, sessionKey: String, sessionID: String?) async throws -> Data {
        try await chatCompletionsWithMetadata(payload: payload, sessionKey: sessionKey, sessionID: sessionID).data
    }

    func chatCompletionsWithMetadata(
        payload: Data,
        sessionKey _: String,
        sessionID _: String?,
    ) async throws -> HermesChatTransportMetadata {
        // 1. Parse the inbound OpenAI payload.
        guard
            let openAI = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let messages = openAI["messages"] as? [[String: Any]]
        else {
            throw ProviderError.permanent(
                provider: kind,
                status: 400,
                body: "invalid OpenAI payload: cannot parse messages",
            )
        }

        // 2. Translate to Anthropic shape.
        var systemPrompt: String?
        var anthropicMessages: [[String: Any]] = []
        for message in messages {
            let role = message["role"] as? String ?? "user"
            let content = message["content"] as? String ?? ""
            if role == "system" {
                // Concatenate consecutive system messages on the boundary
                // between OpenAI's permissive "system anywhere" model and
                // Anthropic's single top-level `system` field.
                systemPrompt = systemPrompt.map { "\($0)\n\n\(content)" } ?? content
            } else {
                anthropicMessages.append(["role": role, "content": content])
            }
        }

        let model = (openAI["model"] as? String) ?? "claude-sonnet-4-6"
        let temperature = (openAI["temperature"] as? Double) ?? 0.4
        // Anthropic requires `max_tokens`; OpenAI treats it optional.
        let maxTokens = (openAI["max_tokens"] as? Int) ?? 4096

        var body: [String: Any] = [
            "model": model,
            "messages": anthropicMessages,
            "max_tokens": maxTokens,
            "temperature": temperature,
        ]
        if let systemPrompt {
            body["system"] = systemPrompt
        }

        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw ProviderError.permanent(
                provider: kind,
                status: 400,
                body: "failed to serialize anthropic payload",
            )
        }

        // 3. Resolve credentials + dispatch.
        let (resolvedKey, resolvedBaseURL) = await resolveCredentials()
        let url = resolvedBaseURL.appendingPathComponent("v1").appendingPathComponent("messages")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(resolvedKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

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
            // 4. Translate Anthropic → OpenAI response shape.
            let openAIResponse = Self.translateResponse(body: data, model: model)
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
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            return HermesChatTransportMetadata(data: responseData, headers: headers)
        }

        let error = ProviderErrorClassifier.classify(provider: kind, status: status, body: data)
        logger.error("anthropic upstream \(error.reasonCode) status=\(status)")
        throw error
    }

    private func resolveCredentials() async -> (key: String, baseURL: URL) {
        guard let userCredentials,
              let user = LLMRoutingContext.currentUser,
              let tenantID = try? user.requireID()
        else {
            return (apiKey, baseURL)
        }
        do {
            guard let creds = try await userCredentials.credential(for: kind, tenantID: tenantID) else {
                return (apiKey, baseURL)
            }
            return (creds.apiKey ?? apiKey, creds.baseURL ?? baseURL)
        } catch {
            logger.error("user credential lookup failed for anthropic: \(error)")
            return (apiKey, baseURL)
        }
    }

    /// Translate Anthropic `/v1/messages` response → OpenAI chat
    /// completions response shape. Mirrors the projection
    /// `GeminiContentsAdapter` does for Gemini.
    static func translateResponse(body: Data, model: String) -> [String: Any] {
        guard
            let anthropic = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            return ["error": "unparseable anthropic response"]
        }
        let textChunks = (anthropic["content"] as? [[String: Any]] ?? [])
            .compactMap { ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil }
        let assistantText = textChunks.joined(separator: "")
        let usage = anthropic["usage"] as? [String: Any] ?? [:]
        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        return [
            "id": anthropic["id"] as? String ?? UUID().uuidString,
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [[
                "index": 0,
                "message": [
                    "role": "assistant",
                    "content": assistantText,
                ],
                "finish_reason": anthropic["stop_reason"] as? String ?? "stop",
            ]],
            "usage": [
                "prompt_tokens": inputTokens,
                "completion_tokens": outputTokens,
                "total_tokens": inputTokens + outputTokens,
            ],
        ]
    }
}
