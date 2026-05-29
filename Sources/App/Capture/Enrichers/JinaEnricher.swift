import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-240 / spec ticket #3 — full-page markdown via jina.ai's reader API.
///
/// Used as a tier-2 post-processor inside `URLEnrichmentService`: runs only
/// when the primary enricher returned shallow metadata. Populates
/// `EnrichedMetadata.body` with up to 1MB of clean markdown so Hermes can
/// reason about real article content instead of just `og:title` /
/// `og:description`.
///
/// Retries once on 429 (the only jina rate-limit signal); other failures
/// throw and let the caller fall back to whatever the primary enricher
/// already produced.
struct JinaEnricher: URLEnricher {
    static let bodyCapBytes = 1 * 1024 * 1024
    static let timeoutSeconds: TimeInterval = 15
    static let retryDelaySeconds: TimeInterval = 2

    let session: URLSession
    let apiKey: String?
    let logger: Logger

    init(session: URLSession = .shared, apiKey: String? = nil, logger: Logger) {
        self.session = session
        self.apiKey = apiKey
        self.logger = logger
    }

    func canHandle(url _: URL) -> Bool { true }

    func enrich(url: URL) async throws -> EnrichedMetadata {
        do {
            return try await dispatch(url: url)
        } catch JinaEnricherError.rateLimited {
            logger.warning("jina rate-limited; retrying once after \(Self.retryDelaySeconds)s")
            try await Task.sleep(for: .seconds(Self.retryDelaySeconds))
            return try await dispatch(url: url)
        }
    }

    private func dispatch(url: URL) async throws -> EnrichedMetadata {
        guard let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let jinaURL = URL(string: "https://r.jina.ai/\(encoded)")
        else {
            throw JinaEnricherError.invalidURL
        }

        var req = URLRequest(url: jinaURL, timeoutInterval: Self.timeoutSeconds)
        req.httpMethod = "GET"
        req.setValue("text/markdown", forHTTPHeaderField: "Accept")
        req.setValue("markdown", forHTTPHeaderField: "X-Return-Format")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw JinaEnricherError.invalidResponse
        }
        if http.statusCode == 429 {
            throw JinaEnricherError.rateLimited
        }
        if !(200 ..< 300).contains(http.statusCode) {
            throw JinaEnricherError.upstreamStatus(http.statusCode)
        }

        let cappedData = data.count > Self.bodyCapBytes ? data.prefix(Self.bodyCapBytes) : data.prefix(data.count)
        let body = String(data: Data(cappedData), encoding: .utf8) ?? ""

        var metadata = EnrichedMetadata(url: url.absoluteString)
        metadata.body = body
        return metadata
    }
}

enum JinaEnricherError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case rateLimited
    case upstreamStatus(Int)
}
