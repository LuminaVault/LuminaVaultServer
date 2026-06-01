import Foundation
import Logging

/// HER-43 (Slice 2) — fetches a user-supplied RSS/Atom feed and returns its
/// item links for staging. Unlike the API connectors, the feed URL is
/// user-supplied, so it is SSRF-guarded (`URLEnricherGuard.isPublic`) before
/// fetching; the staged item links are guarded again downstream by
/// `LinkCaptureService`.
struct RSSConnector: PluginConnector {
    let binding = "rss"
    let http: ConnectorHTTPClient
    let logger: Logger

    func fetchURLs(config: [String: String], tenantID: UUID) async throws -> [String] {
        let raw = (config["feed_url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw ConnectorError.missingConfig("feed_url") }
        guard let url = URL(string: raw), URLEnricherGuard.isPublic(url) else {
            throw ConnectorError.invalidConfig("feed_url")
        }

        let resp = try await http.get(url: url, headers: ["Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml"])
        guard resp.status == 200 else { throw ConnectorError.upstreamFailure(resp.status) }

        let xml = String(decoding: resp.body, as: UTF8.self)
        let urls = Self.extractLinks(xml)
        logger.info("rss connector tenant=\(tenantID) urls=\(urls.count)")
        return urls
    }

    /// Extract http(s) item links from an RSS or Atom document, order-preserving
    /// dedupe. Captures RSS `<link>URL</link>` and Atom `<link href="URL"/>`.
    /// Regex over markup (matching the existing `parseBookmarksHTML` style) is
    /// sufficient — we only need source URLs to hand to the link pipeline.
    static func extractLinks(_ xml: String) -> [String] {
        let patterns = [
            #"<link>\s*(https?://[^<\s]+)\s*</link>"#,
            #"<link\b[^>]*\bhref\s*=\s*["'](https?://[^"']+)["']"#,
        ]
        let ns = xml as NSString
        var urls: [String] = []
        var seen = Set<String>()
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            re.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let u = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if u.hasPrefix("http://") || u.hasPrefix("https://"), seen.insert(u).inserted {
                    urls.append(u)
                }
            }
        }
        return urls
    }
}
