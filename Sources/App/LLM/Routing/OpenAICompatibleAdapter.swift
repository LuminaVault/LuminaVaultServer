import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-164 — `ProviderAdapter` covering every OpenAI-API-compatible
/// provider in one shot: Together, Groq, Fireworks, DeepInfra, and
/// DeepSeek-direct. The five differ only in `baseURL`, `apiKey`, and
/// the `region` tag — request shape, auth header, and response shape
/// are identical (`Authorization: Bearer <key>` →
/// `POST /v1/chat/completions` → standard OpenAI chat completions
/// JSON).
///
/// `kind` is set at construction so log lines, metrics labels, and
/// `ProviderError` cases identify the upstream correctly.
struct OpenAICompatibleAdapter: ProviderAdapter {
    let kind: ProviderKind
    let apiKey: String
    let baseURL: URL
    let session: URLSession
    let logger: Logger

    init(
        kind: ProviderKind,
        apiKey: String,
        baseURL: URL,
        session: URLSession = .shared,
        logger: Logger,
    ) {
        self.kind = kind
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.logger = logger
    }

    func chatCompletions(payload: Data, profileUsername: String) async throws -> Data {
        try await chatCompletionsWithMetadata(payload: payload, profileUsername: profileUsername).data
    }

    func chatCompletionsWithMetadata(payload: Data, profileUsername _: String) async throws -> HermesChatTransportMetadata {
        let url = Self.endpoint(for: kind, baseURL: baseURL)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload

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
            return HermesChatTransportMetadata(data: data, headers: headers)
        }
        let preview = String(data: data.prefix(512), encoding: .utf8)
        // Mirror HermesGatewayAdapter: 429 + 5xx are retryable transient
        // failures; everything else is a permanent payload-shape problem
        // (or auth) that another upstream wouldn't fix.
        if status == 429 || (500 ..< 600).contains(status) {
            logger.error("\(kind.rawValue) upstream transient \(status): \(preview ?? "<binary>")")
            throw ProviderError.transient(provider: kind, status: status, body: preview)
        }
        logger.error("\(kind.rawValue) upstream permanent \(status): \(preview ?? "<binary>")")
        throw ProviderError.permanent(provider: kind, status: status, body: preview)
    }

    // MARK: - Health check

    /// HER-164 — single low-cost smoke request used by
    /// `/admin/llm/health`. Sends `max_tokens: 1` so per-request billing
    /// stays under a cent across providers. Treats any reachable status
    /// (2xx OR 4xx) as `ok` — a 4xx still proves the upstream answered.
    /// Only network-layer failures flip `ok` to false.
    func healthCheck(timeout: Duration = .seconds(3)) async -> HealthCheckResult {
        let url = Self.endpoint(for: kind, baseURL: baseURL)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = TimeInterval(timeout.components.seconds)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.pingPayload()
        let start = ContinuousClock.now
        do {
            let (_, response) = try await session.data(for: req)
            let elapsed = ContinuousClock.now - start
            let latencyMs = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return HealthCheckResult(ok: status > 0, latencyMs: max(0, latencyMs), error: nil)
        } catch {
            let elapsed = ContinuousClock.now - start
            let latencyMs = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            return HealthCheckResult(ok: false, latencyMs: max(0, latencyMs), error: String(describing: error))
        }
    }

    static func pingPayload() -> Data {
        let body: [String: Any] = [
            "model": "ping",
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 1,
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// Routes the chat-completions URL per provider. Every supported
    /// upstream uses `/v1/chat/completions`; DeepInfra's OpenAI surface
    /// ships under `/v1/openai/...` so its default baseURL pre-bakes
    /// `/v1/openai` and we still append `chat/completions` below.
    static func endpoint(for kind: ProviderKind, baseURL: URL) -> URL {
        switch kind {
        case .deepInfra:
            // DeepInfra-default baseURL = `https://api.deepinfra.com/v1/openai`.
            // If callers override baseURL they keep the prefix themselves.
            return baseURL.appendingPathComponent("chat").appendingPathComponent("completions")
        default:
            return baseURL
                .appendingPathComponent("v1")
                .appendingPathComponent("chat")
                .appendingPathComponent("completions")
        }
    }

    /// Hard-coded production defaults; overridable via
    /// `llm.provider.<key>.baseURL` env knob.
    static func defaultBaseURL(for kind: ProviderKind) -> URL {
        switch kind {
        case .together: URL(string: "https://api.together.xyz")!
        case .groq: URL(string: "https://api.groq.com")!
        case .fireworks: URL(string: "https://api.fireworks.ai/inference")!
        case .deepInfra: URL(string: "https://api.deepinfra.com/v1/openai")!
        case .deepseekDirect: URL(string: "https://api.deepseek.com")!
        default: URL(string: "https://invalid.local")!
        }
    }
}

/// Lightweight result struct shared with `LLMHealthController`.
struct HealthCheckResult: Sendable {
    let ok: Bool
    let latencyMs: Int
    let error: String?
}
