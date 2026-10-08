import Foundation
import Logging
import NIOConcurrencyHelpers

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-252 — `ProviderAdapter` that translates an OpenAI chat-completions
/// payload into Anthropic Messages v1 API shape, calls
/// `POST /v1/messages`, and translates the response back to OpenAI shape
/// so the rest of the server pipeline sees a uniform wire format.
///
/// The translation itself (messages, tools, images, thinking, JSON output,
/// stream records) lives in `AnthropicAdapter+Translation.swift`.
///
/// Auth: `x-api-key: <key>` + `anthropic-version: 2023-06-01` (the
/// last stable Messages API version pinned in the public SDK).
///
/// **Managed trial.** When `managedTrial` is set (`ANTHROPIC_FIRST=true` plus a
/// key), requests that spend the platform key get the trial's model, effort and
/// thinking settings, and every failure is reshaped so `RoutedLLMTransport`
/// fails over rather than stopping (see `managedFailure`). When the deployment
/// has no registry Anthropic key of its own, the trial key is reserved for the
/// trial model: any other Anthropic model on the platform key fails exactly as
/// it did before the trial, when that key was empty.
struct AnthropicAdapter: ProviderAdapter {
    let kind: ProviderKind = .anthropic
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession
    private let logger: Logger
    private let userCredentials: UserCredentialStore?
    private let managedTrial: AnthropicManagedTrialConfig?
    var acceptsUserCredentials: Bool {
        userCredentials != nil
    }

    /// Anthropic API version pin. Bumping this requires a release-notes
    /// review of behavior changes (tool use, prompt caching, etc.).
    static let apiVersion = "2023-06-01"

    init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        session: URLSession = .shared,
        logger: Logger,
        userCredentials: UserCredentialStore? = nil,
        managedTrial: AnthropicManagedTrialConfig? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.logger = logger
        self.userCredentials = userCredentials
        self.managedTrial = managedTrial
    }

    func chatCompletions(payload: Data, sessionKey: String, sessionID: String?) async throws -> Data {
        try await chatCompletionsWithMetadata(payload: payload, sessionKey: sessionKey, sessionID: sessionID).data
    }

    func chatCompletionsWithMetadata(
        payload: Data,
        sessionKey _: String,
        sessionID _: String?
    ) async throws -> HermesChatTransportMetadata {
        // 1. Resolve credentials first: whether the platform key is spent
        //    decides the model default, thinking/effort and error mapping.
        let credentials = try await resolveCredentials()
        let options = requestOptions(for: credentials)

        // 2. Translate the OpenAI payload to Anthropic Messages shape.
        let translated = try Self.translateRequest(payload: payload, stream: false, options: options)
        try guardTrialKeyModel(translated.model, credentials: credentials)
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: translated.body)
        } catch {
            throw ProviderError.permanent(
                provider: kind,
                status: 400,
                body: "failed to serialize anthropic payload"
            )
        }

        // 3. Dispatch.
        let url = credentials.baseURL.appendingPathComponent("v1").appendingPathComponent("messages")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(credentials.key, forHTTPHeaderField: "x-api-key")
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
            let translatedResponse = try Self.translateResponse(
                body: data,
                model: translated.model,
                stripJSONFences: translated.stripJSONFences
            )
            if let usage = translatedResponse.usage {
                logUsage(usage, model: translated.model, managed: options.managed, streamed: false)
            }
            let responseData: Data
            do {
                responseData = try JSONSerialization.data(withJSONObject: translatedResponse.openAI)
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

        let error = options.managed
            ? Self.managedFailure(status: status, body: data)
            : ProviderErrorClassifier.classify(provider: kind, status: status, body: data)
        logger.error("anthropic upstream \(error.reasonCode) status=\(status)")
        throw error
    }

    // MARK: - Streaming (P2)

    /// Native per-token streaming via the Anthropic Messages SSE protocol:
    /// `content_block_delta` carries `delta.text`; `message_delta` carries
    /// the terminal `stop_reason` and cumulative usage; `message_stop` ends
    /// the stream.
    ///
    /// `RoutedLLMTransport` does not meter streams, so usage from
    /// `message_start` / `message_delta` is logged here as `anthropic_usage`.
    func chatStream(payload: Data, sessionKey _: String, sessionID _: String?) -> AsyncThrowingStream<ChatStreamChunk, Error> {
        let usage = NIOLockedValueBox(AnthropicStreamState())
        // Set once credentials resolve inside `makeRequest`; read when an error
        // leaves the stream so the managed failover mapping can apply.
        let managed = NIOLockedValueBox(false)
        let logger = logger
        let upstream = ProviderStreamKit.run(
            kind: kind,
            framing: .sse,
            logger: logger,
            makeRequest: {
                let credentials = try await resolveCredentials()
                let options = requestOptions(for: credentials)
                managed.withLockedValue { $0 = options.managed }
                let translated = try Self.translateRequest(payload: payload, stream: true, options: options)
                try guardTrialKeyModel(translated.model, credentials: credentials)
                usage.withLockedValue { $0.model = translated.model }
                let bodyData = try JSONSerialization.data(withJSONObject: translated.body)
                return ProviderStreamRequest(
                    url: credentials.baseURL.appendingPathComponent("v1").appendingPathComponent("messages"),
                    headers: [
                        ("Accept", "text/event-stream"),
                        ("x-api-key", credentials.key),
                        ("anthropic-version", Self.apiVersion),
                    ],
                    body: bodyData
                )
            },
            process: { record, yield in
                let (done, state) = try usage.withLockedValue { current in
                    let finished = try Self.processStreamRecord(record, state: &current, yield: yield)
                    return (finished, current)
                }
                if done {
                    Self.logUsage(
                        state.usage,
                        model: state.model,
                        managed: managed.withLockedValue { $0 },
                        streamed: true,
                        logger: logger
                    )
                }
                return done
            }
        )
        let (stream, continuation) = AsyncThrowingStream<ChatStreamChunk, Error>.makeStream()
        let relay = Task {
            do {
                for try await chunk in upstream {
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch let error as ProviderError where managed.withLockedValue({ $0 }) {
                continuation.finish(throwing: Self.remapManaged(error))
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in relay.cancel() }
        return stream
    }

    // MARK: - Credentials

    struct ResolvedCredentials {
        let key: String
        let baseURL: URL
        /// The deployment key is being spent (managed, or no tenant key).
        let isPlatform: Bool
        /// The platform key is the trial's own (no registry Anthropic key).
        let isTrialOnlyKey: Bool
    }

    /// Managed mode spends the platform key; BYOK mode spends the tenant's key
    /// or throws. See `OpenAICompatibleAdapter.resolveCredentials` for the full
    /// rationale — this is the same rule for Anthropic.
    private func resolveCredentials() async throws -> ResolvedCredentials {
        let mode = LLMRoutingContext.credentialMode
        if mode == .managed {
            return platformCredentials()
        }

        guard let userCredentials,
              let user = LLMRoutingContext.currentUser,
              let tenantID = try? user.requireID()
        else {
            if mode == .byok {
                logger.error("byok request for anthropic has no resolvable tenant; failing closed")
                throw BYOKKeysRequiredError()
            }
            return platformCredentials()
        }

        let creds: UserCredentialStore.ResolvedCredential?
        do {
            creds = try await userCredentials.credential(for: kind, tenantID: tenantID)
        } catch {
            logger.error("user credential lookup failed for anthropic: \(error)")
            if mode == .byok {
                throw BYOKKeysRequiredError()
            }
            return platformCredentials()
        }

        if let key = creds?.apiKey, !key.isEmpty {
            return ResolvedCredentials(key: key, baseURL: creds?.baseURL ?? baseURL, isPlatform: false, isTrialOnlyKey: false)
        }
        if mode == .byok {
            logger.error("byok request for anthropic has no usable credential; failing closed")
            throw BYOKKeysRequiredError()
        }
        return platformCredentials()
    }

    /// The registry key when the deployment has one; otherwise the trial key.
    private func platformCredentials() -> ResolvedCredentials {
        if apiKey.isEmpty, let managedTrial {
            return ResolvedCredentials(key: managedTrial.apiKey, baseURL: baseURL, isPlatform: true, isTrialOnlyKey: true)
        }
        return ResolvedCredentials(key: apiKey, baseURL: baseURL, isPlatform: true, isTrialOnlyKey: false)
    }

    private func requestOptions(for credentials: ResolvedCredentials) -> AnthropicRequestOptions {
        guard credentials.isPlatform, let managedTrial else { return AnthropicRequestOptions() }
        return AnthropicRequestOptions(managed: true, trial: managedTrial)
    }

    /// Before the trial this adapter's platform key was empty, so any managed
    /// Anthropic route — a locked profile, an "ask another model" override —
    /// got a 401. The trial key must not quietly start paying for those at
    /// Sonnet/Opus rates; they keep failing the same way.
    private func guardTrialKeyModel(_ model: String, credentials: ResolvedCredentials) throws {
        guard credentials.isTrialOnlyKey, let managedTrial, model != managedTrial.model else { return }
        throw ProviderError.permanent(
            provider: kind,
            status: 401,
            body: "anthropic platform key is reserved for the managed trial model"
        )
    }

    // MARK: - Managed failover mapping

    /// Failover rule for platform-paid traffic: every failure must hand the
    /// request to the next candidate. 401/402/403, and a 400 that names the
    /// usage limit or credit balance (how a workspace spend cap surfaces), are
    /// billing/auth — `.creditExhausted`. Everything else, including 400, 404,
    /// 429, 5xx and 529, is `.transient`. BYOK keeps `ProviderErrorClassifier`.
    static func managedFailure(status: Int, body: Data?) -> ProviderError {
        let preview = body.flatMap { String(data: $0.prefix(2048), encoding: .utf8) }
        let lower = preview?.lowercased() ?? ""
        switch status {
        case 401, 402, 403:
            return .creditExhausted(provider: .anthropic, status: status, body: preview)
        case 400 where lower.contains("usage limit") || lower.contains("credit balance"):
            return .creditExhausted(provider: .anthropic, status: status, body: preview)
        default:
            return .transient(provider: .anthropic, status: status, body: preview)
        }
    }

    /// Streaming counterpart: `ProviderStreamKit` has already classified the
    /// HTTP failure with the shared classifier; re-map the non-recoverable ones.
    static func remapManaged(_ error: ProviderError) -> ProviderError {
        switch error {
        case let .permanent(_, status, body):
            managedFailure(status: status, body: body.map { Data($0.utf8) })
        case .transient, .network, .creditExhausted:
            error
        }
    }

    // MARK: - Usage logging

    private func logUsage(_ usage: AnthropicUsage, model: String, managed: Bool, streamed: Bool) {
        Self.logUsage(usage, model: model, managed: managed, streamed: streamed, logger: logger)
    }

    private static func logUsage(_ usage: AnthropicUsage, model: String, managed: Bool, streamed: Bool, logger: Logger) {
        logger.info("anthropic_usage", metadata: [
            "event": .string("anthropic_usage"),
            "model": .string(model),
            "managed": .stringConvertible(managed),
            "streamed": .stringConvertible(streamed),
            "input_tokens": .stringConvertible(usage.inputTokens),
            "output_tokens": .stringConvertible(usage.outputTokens),
            "cache_read_input_tokens": .stringConvertible(usage.cacheReadInputTokens),
            "cache_creation_input_tokens": .stringConvertible(usage.cacheCreationInputTokens),
            "est_cost_usd_micros": .stringConvertible(usage.estimatedCostUsdMicros),
        ])
    }
}
