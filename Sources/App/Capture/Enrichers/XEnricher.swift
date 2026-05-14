import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct XEnricher: URLEnricher {
    func canHandle(url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("twitter.com") || host.contains("x.com")
    }

    func enrich(url: URL) async throws -> EnrichedMetadata {
        var metadata = EnrichedMetadata(url: url.absoluteString)

        guard let oembedURL = URL(string: "https://publish.twitter.com/oembed?url=\(url.absoluteString)") else {
            return metadata
        }

        do {
            var request = URLRequest(url: oembedURL)
            request.timeoutInterval = 10
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                metadata.author = json["author_name"] as? String

                // Extract tweet text from the embedded HTML
                if let html = json["html"] as? String {
                    // Very basic regex to extract the paragraph content
                    if let regex = try? NSRegularExpression(pattern: "<p[^>]*>(.*?)</p>", options: .dotMatchesLineSeparators),
                       let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
                    {
                        if let range = Range(match.range(at: 1), in: html) {
                            var text = String(html[range])

                            // Strip inner tags like <a ...> and decode entities
                            if let stripRegex = try? NSRegularExpression(pattern: "<[^>]+>") {
                                text = stripRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                            }

                            text = text
                                .replacingOccurrences(of: "&#39;", with: "'")
                                .replacingOccurrences(of: "&quot;", with: "\"")
                                .replacingOccurrences(of: "&amp;", with: "&")
                                .replacingOccurrences(of: "&lt;", with: "<")
                                .replacingOccurrences(of: "&gt;", with: ">")
                                .trimmingCharacters(in: .whitespacesAndNewlines)

                            metadata.description = text
                        }
                    }
                }
            }
        } catch {
            // Fallback or ignore
        }

        return metadata
    }
}
