import AsyncHTTPClient
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// SSRF hardening for user-provided (BYO-Hermes) endpoints.
///
/// `SSRFGuard` validates the configured URL (and re-resolves at request time),
/// but a malicious or compromised endpoint can still answer with a `30x`
/// redirect to an internal / cloud-metadata host (`169.254.169.254`,
/// `10.0.0.1`, …). A redirect-following HTTP client would chase that target
/// **after** validation — a classic SSRF bypass. These clients refuse to
/// follow redirects: a `3xx` is returned verbatim and treated as a non-2xx
/// failure by the caller.
final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // nil → do not follow; deliver the 3xx response as-is.
        completionHandler(nil)
    }
}

enum BYOHTTP {
    /// `URLSession` that never follows redirects. The delegate is stateless, so
    /// a single shared instance is safe. Used by the BYO-Hermes proxy dispatch
    /// (`HermesGatewayAdapter`) and the `/test` probe (`HermesConfigController`).
    static let session: URLSession = .init(
        configuration: .ephemeral,
        delegate: NoRedirectURLSessionDelegate(),
        delegateQueue: nil
    )

    /// `AsyncHTTPClient` that never follows redirects, for the BYO-Hermes chat
    /// **stream** path. Process-lifetime singleton (never deinited, so no
    /// shutdown warning — same lifecycle model as `HTTPClient.shared`).
    static let httpClient: HTTPClient = .init(
        eventLoopGroupProvider: .singleton,
        configuration: HTTPClient.Configuration(redirectConfiguration: .disallow)
    )
}
