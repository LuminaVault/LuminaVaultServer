import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-252 — `ProviderAdapter` for a user's self-hosted Ollama instance.
/// No API key (host trusts whoever can reach it); the `baseURL` is the
/// user-supplied host URL stored in `user_provider_credentials`
/// (e.g. `http://192.168.1.42:11434` or a Tailscale name).
///
/// Wire format: `POST /api/chat` with `{model, messages, stream: false}`
/// returning `{message: {role, content}}`. Different enough from OpenAI
/// that we translate both directions (mirrors AnthropicAdapter +
/// GeminiContentsAdapter).
struct OllamaAdapter: ProviderAdapter {
    let kind: ProviderKind = .ollama
    /// Construction-time default for deployments that ship a managed
    /// Ollama host. Most installs will leave this as `localhost` and
    /// let users override via `user_provider_credentials.base_url`.
    private let defaultBaseURL: URL
    private let session: URLSession
    private let logger: Logger
    private let userCredentials: UserCredentialStore?

    init(
        defaultBaseURL: URL = URL(string: "http://localhost:11434")!,
        session: URLSession = .shared,
        logger: Logger,
        userCredentials: UserCredentialStore? = nil
    ) {
        self.defaultBaseURL = defaultBaseURL
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
        sessionID _: String?
    ) async throws -> HermesChatTransportMetadata {
        // 1. Parse the inbound OpenAI payload.
        guard
            let openAI = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let messages = openAI["messages"] as? [[String: Any]]
        else {
            throw ProviderError.permanent(
                provider: kind,
                status: 400,
                body: "invalid OpenAI payload"
            )
        }
        let model = (openAI["model"] as? String) ?? "llama3.1"

        // 2. Translate to Ollama shape — same `messages` array works,
        //    Ollama treats `system` as a valid role.
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
        ]
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw ProviderError.permanent(
                provider: kind,
                status: 400,
                body: "failed to serialize ollama payload"
            )
        }

        // 3. Resolve per-user base URL (required for any sensible deploy).
        let baseURL = await resolveBaseURL()
        let url = baseURL.appendingPathComponent("api").appendingPathComponent("chat")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
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
            let openAIResponse = Self.translateResponse(body: data, model: model)
            let responseData: Data
            do {
                responseData = try JSONSerialization.data(withJSONObject: openAIResponse)
            } catch {
                throw ProviderError.transient(
                    provider: kind,
                    status: status,
                    body: "failed to encode OpenAI response"
                )
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            return HermesChatTransportMetadata(data: responseData, headers: headers)
        }
        let error = ProviderErrorClassifier.classify(provider: kind, status: status, body: data)
        logger.error("ollama upstream \(error.reasonCode) status=\(status)")
        throw error
    }

    private func resolveBaseURL() async -> URL {
        guard let userCredentials,
              let user = LLMRoutingContext.currentUser,
              let tenantID = try? user.requireID()
        else {
            return defaultBaseURL
        }
        do {
            guard let creds = try await userCredentials.credential(for: kind, tenantID: tenantID),
                  let url = creds.baseURL
            else {
                return defaultBaseURL
            }
            return url
        } catch {
            logger.error("user credential lookup failed for ollama: \(error)")
            return defaultBaseURL
        }
    }

    /// Translate Ollama `/api/chat` response → OpenAI chat completions
    /// response shape.
    static func translateResponse(body: Data, model: String) -> [String: Any] {
        guard
            let ollama = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            return ["error": "unparseable ollama response"]
        }
        let message = ollama["message"] as? [String: Any] ?? [:]
        let content = message["content"] as? String ?? ""
        let promptTokens = ollama["prompt_eval_count"] as? Int ?? 0
        let completionTokens = ollama["eval_count"] as? Int ?? 0
        return [
            "id": "ollama-\(UUID().uuidString)",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [[
                "index": 0,
                "message": [
                    "role": "assistant",
                    "content": content,
                ],
                "finish_reason": ollama["done_reason"] as? String ?? "stop",
            ]],
            "usage": [
                "prompt_tokens": promptTokens,
                "completion_tokens": completionTokens,
                "total_tokens": promptTokens + completionTokens,
            ],
        ]
    }
}
