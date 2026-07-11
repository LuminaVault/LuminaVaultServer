import AsyncHTTPClient
import Foundation
import Logging
import NIOCore

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
struct OpenAICompatibleAdapter: StreamingProviderAdapter {
    let kind: ProviderKind
    let apiKey: String
    let baseURL: URL
    let session: URLSession
    let httpClient: HTTPClient
    let requestTimeout: TimeAmount
    let logger: Logger
    /// HER-252 — optional per-user credential resolver. When present, the
    /// adapter consults the store via `LLMRoutingContext.currentUser` on
    /// every chat call; if the user has a stored credential we use it
    /// (and the user's base URL override, if any), otherwise we fall
    /// back to the construction-time deployment defaults.
    let userCredentials: UserCredentialStore?

    /// Resolver used exclusively for ProviderKind.xai when the user's
    /// credential row has kind "oauth" (SuperGrok linked account). Returns
    /// the tenant Hermes container handle so we can proxy the request
    /// (and models/test pings) through the container using its apiServerKey.
    /// The container performs the actual xAI call using the linked session.
    let xaiOAuthContainerResolver: (@Sendable (UUID) async -> HermesContainerHandle?)?

    init(
        kind: ProviderKind,
        apiKey: String,
        baseURL: URL,
        session: URLSession = .shared,
        httpClient: HTTPClient = .shared,
        requestTimeout: TimeAmount = .seconds(120),
        logger: Logger,
        userCredentials: UserCredentialStore? = nil,
        xaiOAuthContainerResolver: (@Sendable (UUID) async -> HermesContainerHandle?)? = nil
    ) {
        self.kind = kind
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.httpClient = httpClient
        self.requestTimeout = requestTimeout
        self.logger = logger
        self.userCredentials = userCredentials
        self.xaiOAuthContainerResolver = xaiOAuthContainerResolver
    }

    func chatCompletions(payload: Data, sessionKey: String, sessionID: String?) async throws -> Data {
        try await chatCompletionsWithMetadata(payload: payload, sessionKey: sessionKey, sessionID: sessionID).data
    }

    func chatCompletionsWithMetadata(payload: Data, sessionKey _: String, sessionID _: String?) async throws -> HermesChatTransportMetadata {
        // HER-252 — per-user credential lookup. Empty deployment env key
        // + present user key is the canonical BYO mode. Per-user base
        // URL override (e.g. Azure OpenAI proxy) takes precedence over
        // the construction-time default.
        let (resolvedKey, resolvedBaseURL) = await resolveCredentials()
        let url = Self.endpoint(for: kind, baseURL: resolvedBaseURL)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if !resolvedKey.isEmpty {
            req.setValue("Bearer \(resolvedKey)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // HER-252 — OpenRouter requires an HTTP-Referer / X-Title to
        // route requests on shared keys. We set our LuminaVault identity
        // so usage is attributable in OpenRouter's dashboard even when
        // the user is on a personal key.
        if kind == .openRouter {
            req.setValue("https://luminavault.app", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("LuminaVault", forHTTPHeaderField: "X-Title")
        }
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
        // HER-252 — classifier centralizes the 4xx/5xx → ProviderError
        // mapping so 402 + 403-with-credit-marker fall over to the next
        // candidate instead of bubbling up as permanent.
        let error = ProviderErrorClassifier.classify(provider: kind, status: status, body: data)
        logger.error("\(kind.rawValue) upstream \(error.reasonCode) status=\(status)")
        throw error
    }

    func chatCompletionsStream(
        payload: Data,
        sessionKey _: String,
        sessionID _: String?
    ) async throws -> AsyncThrowingStream<ChatStreamChunk, Error> {
        let (resolvedKey, resolvedBaseURL) = await resolveCredentials()
        let url = Self.endpoint(for: kind, baseURL: resolvedBaseURL)
        let streamPayload = Self.setStream(true, in: payload)
        let kind = kind
        let logger = logger
        let httpClient = httpClient
        let requestTimeout = requestTimeout

        let (stream, continuation) = AsyncThrowingStream<ChatStreamChunk, Error>.makeStream()
        let work = Task {
            do {
                let request = Self.makeStreamRequest(
                    url: url,
                    apiKey: resolvedKey,
                    kind: kind,
                    payloadData: streamPayload
                )
                let response = try await httpClient.execute(request, timeout: requestTimeout)
                let status = Int(response.status.code)
                guard (200 ..< 300).contains(status) else {
                    let body = try await Self.collectBodyPreview(response.body)
                    let error = ProviderErrorClassifier.classify(provider: kind, status: status, body: body)
                    logger.error("\(kind.rawValue) stream upstream \(error.reasonCode) status=\(status)")
                    continuation.finish(throwing: error)
                    return
                }
                try await Self.consumeStreamBody(response.body, provider: kind, continuation: continuation, logger: logger)
                continuation.finish()
            } catch let providerError as ProviderError {
                continuation.finish(throwing: providerError)
            } catch let streamError as HermesStreamUpstreamError {
                continuation.finish(throwing: ProviderError.transient(
                    provider: kind,
                    status: 0,
                    body: String(describing: streamError)
                ))
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: ProviderError.network(provider: kind, underlying: error))
            }
        }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    // MARK: - Credential resolution

    /// Resolve the credential + base URL for the current request. Pulls
    /// the user from `LLMRoutingContext.currentUser`, then checks
    /// `UserCredentialStore` for a per-tenant override; falls back to
    /// the construction-time deployment defaults. Errors during lookup
    /// are logged but never thrown — a stale user credential row must
    /// not break the chat path.
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

            // xAI oauth (SuperGrok) special case: the UserCredentialStore
            // (or this resolver) returns the container's key+base when the
            // marker row exists and the tenant is linked. Proxy through the
            // container exactly like the dedicated Grok features do.
            if kind == .xai,
               (creds.apiKey == nil || creds.apiKey?.isEmpty == true),
               let resolver = xaiOAuthContainerResolver,
               let handle = await resolver(tenantID),
               handle.xaiConnectedAt != nil {
                if let containerBase = URL(string: handle.baseURL) {
                    return (key: handle.apiServerKey, baseURL: containerBase)
                }
            }

            let key = creds.apiKey ?? apiKey
            let url = creds.baseURL ?? baseURL
            return (key, url)
        } catch {
            logger.error("user credential lookup failed for \(kind.rawValue): \(error)")
            return (apiKey, baseURL)
        }
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
            let latencyMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return HealthCheckResult(ok: status > 0, latencyMs: max(0, latencyMs), error: nil)
        } catch {
            let elapsed = ContinuousClock.now - start
            let latencyMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
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

    private static func makeStreamRequest(
        url: URL,
        apiKey: String,
        kind: ProviderKind,
        payloadData: Data
    ) -> HTTPClientRequest {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: "Accept", value: "text/event-stream")
        if !apiKey.isEmpty {
            request.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        }
        if kind == .openRouter {
            request.headers.add(name: "HTTP-Referer", value: "https://luminavault.app")
            request.headers.add(name: "X-Title", value: "LuminaVault")
        }
        request.body = .bytes(payloadData)
        return request
    }

    private static func consumeStreamBody<Body: AsyncSequence>(
        _ body: Body,
        provider: ProviderKind,
        continuation: AsyncThrowingStream<ChatStreamChunk, Error>.Continuation,
        logger: Logger
    ) async throws where Body.Element == ByteBuffer {
        var buffer = ""
        let decoder = JSONDecoder()
        var finished = false
        var totalBytes = 0
        let maxStreamBytes = 64 * 1024 * 1024

        for try await chunk in body {
            totalBytes += chunk.readableBytes
            if totalBytes > maxStreamBytes {
                throw ProviderError.transient(provider: provider, status: 0, body: "provider stream exceeded \(maxStreamBytes) bytes")
            }
            if let text = chunk.getString(at: chunk.readerIndex, length: chunk.readableBytes) {
                buffer.append(text)
            }
            while let terminator = buffer.range(of: "\n\n") {
                let record = String(buffer[..<terminator.lowerBound])
                buffer.removeSubrange(..<terminator.upperBound)
                if try DefaultHermesLLMStreamService.processRecord(
                    record,
                    decoder: decoder,
                    yield: { continuation.yield($0) },
                    logger: logger
                ) {
                    finished = true
                    break
                }
            }
            if finished { break }
        }

        if !finished, !buffer.isEmpty {
            _ = try DefaultHermesLLMStreamService.processRecord(
                buffer,
                decoder: decoder,
                yield: { continuation.yield($0) },
                logger: logger
            )
        }
    }

    private static func collectBodyPreview<Body: AsyncSequence>(
        _ body: Body,
        maxBytes: Int = 4096
    ) async throws -> Data where Body.Element == ByteBuffer {
        var data = Data()
        for try await chunk in body {
            var chunk = chunk
            let readable = min(chunk.readableBytes, maxBytes - data.count)
            if readable > 0, let part = chunk.readData(length: readable) {
                data.append(part)
            }
            if data.count >= maxBytes { break }
        }
        return data
    }

    private static func setStream(_ enabled: Bool, in payload: Data) -> Data {
        guard var dict = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            return payload
        }
        dict["stream"] = enabled
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? payload
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
            baseURL.appendingPathComponent("chat").appendingPathComponent("completions")
        default:
            baseURL
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
        // HER-252 — direct API-key paths for per-user credential providers.
        case .xai: URL(string: "https://api.x.ai")!
        case .nvidia: URL(string: "https://integrate.api.nvidia.com")!
        case .openai: URL(string: "https://api.openai.com")!
        case .openRouter: URL(string: "https://openrouter.ai/api")!
        case .nous: URL(string: "https://inference-api.nousresearch.com")!
        default: URL(string: "https://invalid.local")!
        }
    }
}

/// Lightweight result struct shared with `LLMHealthController`.
struct HealthCheckResult {
    let ok: Bool
    let latencyMs: Int
    let error: String?
}
