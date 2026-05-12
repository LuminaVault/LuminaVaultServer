import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-165 — `ProviderAdapter` wrapping the in-VPS Hermes gateway. Same
/// wire format as `URLSessionHermesChatTransport` (kept for back-compat
/// in tests + dev), but throws `ProviderError` so the routed dispatcher
/// can classify failover.
struct HermesGatewayAdapter: ProviderAdapter {
    let kind: ProviderKind = .hermesGateway
    let baseURL: URL
    let session: URLSession
    let logger: Logger

    func chatCompletions(payload: Data, profileUsername: String) async throws -> Data {
        try await chatCompletionsWithMetadata(payload: payload, profileUsername: profileUsername).data
    }

    func chatCompletionsWithMetadata(payload: Data, profileUsername: String) async throws -> HermesChatTransportMetadata {
        let url = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(profileUsername, forHTTPHeaderField: "X-Hermes-Profile")
        req.httpBody = payload

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            // Network-layer failure → recoverable for the dispatcher.
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
        // 429 = rate-limited, retryable. 5xx = upstream broken, retryable.
        // Everything else is permanent — our payload is bad and another
        // provider won't fix it.
        if status == 429 || (500 ..< 600).contains(status) {
            logger.error("hermes upstream transient \(status): \(preview ?? "<binary>")")
            throw ProviderError.transient(provider: kind, status: status, body: preview)
        }
        logger.error("hermes upstream permanent \(status): \(preview ?? "<binary>")")
        throw ProviderError.permanent(provider: kind, status: status, body: preview)
    }
}
