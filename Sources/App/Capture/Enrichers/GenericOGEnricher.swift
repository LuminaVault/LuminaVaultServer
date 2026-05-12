import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct GenericOGEnricher: URLEnricher {
    func canHandle(url _: URL) -> Bool {
        true // Fallback for any URL
    }

    func enrich(url: URL) async throws -> EnrichedMetadata {
        var metadata = EnrichedMetadata(url: url.absoluteString)

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

            let (data, _) = try await URLSession.shared.data(for: request)
            if let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                metadata.title = extractOG(property: "og:title", from: html) ?? extractTag(tag: "title", from: html)
                metadata.description = extractOG(property: "og:description", from: html) ?? extractMeta(name: "description", from: html)
                metadata.imageURL = extractOG(property: "og:image", from: html)
                metadata.author = extractOG(property: "og:site_name", from: html)
            }
        } catch {
            // Ignore errors for the fallback enricher
        }

        return metadata
    }

    private func extractOG(property: String, from html: String) -> String? {
        // Look for <meta property="og:title" content="..."> or <meta content="..." property="og:title">
        let pattern = "<meta\\s+(?:[^>]*?\\s+)?property=[\"']\(property)[\"']\\s+(?:[^>]*?\\s+)?content=[\"']([^\"']*)[\"'][^>]*>|<meta\\s+(?:[^>]*?\\s+)?content=[\"']([^\"']*)[\"']\\s+(?:[^>]*?\\s+)?property=[\"']\(property)[\"'][^>]*>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
        {
            // content could be in capture group 1 or 2
            if match.range(at: 1).location != NSNotFound, let range = Range(match.range(at: 1), in: html) {
                return decodeEntities(String(html[range]))
            }
            if match.range(at: 2).location != NSNotFound, let range = Range(match.range(at: 2), in: html) {
                return decodeEntities(String(html[range]))
            }
        }
        return nil
    }

    private func extractMeta(name: String, from html: String) -> String? {
        let pattern = "<meta\\s+(?:[^>]*?\\s+)?name=[\"']\(name)[\"']\\s+(?:[^>]*?\\s+)?content=[\"']([^\"']*)[\"'][^>]*>|<meta\\s+(?:[^>]*?\\s+)?content=[\"']([^\"']*)[\"']\\s+(?:[^>]*?\\s+)?name=[\"']\(name)[\"'][^>]*>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
        {
            if match.range(at: 1).location != NSNotFound, let range = Range(match.range(at: 1), in: html) {
                return decodeEntities(String(html[range]))
            }
            if match.range(at: 2).location != NSNotFound, let range = Range(match.range(at: 2), in: html) {
                return decodeEntities(String(html[range]))
            }
        }
        return nil
    }

    private func extractTag(tag: String, from html: String) -> String? {
        let pattern = "<\(tag)[^>]*>(.*?)</\(tag)>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
        {
            if let range = Range(match.range(at: 1), in: html) {
                return decodeEntities(String(html[range]))
            }
        }
        return nil
    }

    private func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
