import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-165 — `ProviderAdapter` wrapping the in-VPS Hermes gateway. Same
/// wire format as `URLSessionHermesChatTransport` (kept for back-compat
/// in tests + dev), but throws `ProviderError` so the routed dispatcher
/// can classify failover.
///
/// HER-223 — when `LLMRoutingContext.currentResolution.isUserOverride` is
/// true, dispatch against the user's hosted gateway (the row stored in
/// `user_hermes_config`) instead of the managed default. The override
/// also injects the decrypted `Authorization` header. Falls back to the
/// adapter's construction-time `baseURL` when no override is in scope.
///
/// HER-240 — Per-request `URLRequest.timeoutInterval` is `requestTimeoutSeconds`
/// (90s). `chatCompletionsWithMetadata` retries once on `URLError.timedOut`
/// for non-streamed payloads, with a 2s sleep between attempts. Streamed
/// payloads never retry — partial output may have shipped to the client.
///
/// Interaction with `RoutedLLMTransport`: the dispatcher fails over to the
/// next candidate on any recoverable `ProviderError`, so a timed-out request
/// can incur up to 2 × N upstream attempts where N is the routing decision's
/// candidate count. With a 3-candidate decision that is 6 attempts and up
/// to ~12s of accumulated retry-sleep before the final `UpstreamErrorResponse`
/// is thrown. Acceptable for current candidate counts; revisit if N grows.
struct HermesGatewayAdapter: ProviderAdapter {
    let kind: ProviderKind = .hermesGateway
    let baseURL: URL
    let session: URLSession
    let logger: Logger
    /// HER-254: Bearer token for the managed default gateway. Sent as
    /// `Authorization: Bearer <key>` when present and no user override is
    /// in scope. Required by Hermes when its api_server binds 0.0.0.0.
    let defaultAuthHeader: String?

    /// Per-request timeout for LLM completions. Default URLSession is ~60s
    /// which can truncate long responses. 90s gives headroom; the retry-once
    /// wrapper handles transient timeouts on top of this.
    static let requestTimeoutSeconds: TimeInterval = 90

    init(baseURL: URL, session: URLSession, logger: Logger, defaultAuthHeader: String? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.logger = logger
        self.defaultAuthHeader = defaultAuthHeader
    }

    func chatCompletions(payload: Data, sessionKey: String, sessionID: String?) async throws -> Data {
        try await chatCompletionsWithMetadata(payload: payload, sessionKey: sessionKey, sessionID: sessionID).data
    }

    func chatCompletionsWithMetadata(payload: Data, sessionKey: String, sessionID: String?) async throws -> HermesChatTransportMetadata {
        let resolution = LLMRoutingContext.currentResolution
        let dispatchBaseURL: URL
        let authHeader: String?
        if let resolution, resolution.isUserOverride {
            dispatchBaseURL = resolution.baseURL
            authHeader = resolution.authHeader
        } else {
            dispatchBaseURL = baseURL
            authHeader = defaultAuthHeader
        }

        let isStream = Self.isStreaming(payload: payload)
        do {
            return try await dispatch(payload: payload, sessionKey: sessionKey, sessionID: sessionID, baseURL: dispatchBaseURL, authHeader: authHeader)
        } catch let error as ProviderError {
            // Retry-once on timeout for non-streamed payloads only.
            guard case let .network(_, underlying) = error,
                  let urlError = underlying as? URLError,
                  urlError.code == .timedOut,
                  !isStream
            else {
                throw error
            }
            logger.warning("hermes upstream timed out; retrying once after 2s")
            try await Task.sleep(for: .seconds(2))
            return try await dispatch(payload: payload, sessionKey: sessionKey, sessionID: sessionID, baseURL: dispatchBaseURL, authHeader: authHeader)
        }
    }

    private func dispatch(
        payload: Data,
        sessionKey: String,
        sessionID: String?,
        baseURL: URL,
        authHeader: String?,
    ) async throws -> HermesChatTransportMetadata {
        let url = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        var req = URLRequest(url: url, timeoutInterval: Self.requestTimeoutSeconds)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(sessionKey, forHTTPHeaderField: "X-Hermes-Session-Key")
        if let sessionID, !sessionID.isEmpty {
            req.setValue(sessionID, forHTTPHeaderField: "X-Hermes-Session-Id")
        }
        if let authHeader, !authHeader.isEmpty {
            req.setValue(authHeader, forHTTPHeaderField: "Authorization")
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
        logger.error("hermes upstream \(error.reasonCode) status=\(status)")
        throw error
    }

    /// Cheap parse of the `stream` field from the chat-completions payload.
    /// Returns false (default) if unparseable.
    private static func isStreaming(payload: Data) -> Bool {
        guard
            let any = try? JSONSerialization.jsonObject(with: payload),
            let dict = any as? [String: Any],
            let stream = dict["stream"] as? Bool
        else {
            return false
        }
        return stream
    }
}
