import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct YouTubeEnricher: URLEnricher {
    func canHandle(url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("youtube.com") || host.contains("youtu.be")
    }

    func enrich(url: URL) async throws -> EnrichedMetadata {
        var metadata = EnrichedMetadata(url: url.absoluteString)

        // 1. Fetch oEmbed metadata
        guard let oembedURL = URL(string: "https://www.youtube.com/oembed?url=\(url.absoluteString)&format=json") else {
            return metadata
        }

        do {
            var request = URLRequest(url: oembedURL)
            request.timeoutInterval = 10
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                metadata.title = json["title"] as? String
                metadata.author = json["author_name"] as? String
                metadata.imageURL = json["thumbnail_url"] as? String
            }
        } catch {
            // Fallback: Continue without oEmbed
        }

        // 2. Best-effort Transcript Scraping
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            // Set a user agent to avoid basic blocks
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

            let (htmlData, _) = try await URLSession.shared.data(for: req)
            if let html = String(data: htmlData, encoding: .utf8) {
                // Look for captionTracks JSON string in ytInitialPlayerResponse
                if let regex = try? NSRegularExpression(pattern: "\"captionTracks\":\\s*\\[\\s*\\{\\s*\"baseUrl\":\\s*\"([^\"]+)\""),
                   let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
                {
                    if let range = Range(match.range(at: 1), in: html) {
                        var captionURLStr = String(html[range])
                        // Unescape unicode sequences if any (basic replace)
                        captionURLStr = captionURLStr.replacingOccurrences(of: "\\u0026", with: "&")

                        if let captionURL = URL(string: captionURLStr) {
                            var captionReq = URLRequest(url: captionURL)
                            captionReq.timeoutInterval = 10
                            let (xmlData, _) = try await URLSession.shared.data(for: captionReq)
                            if let xmlString = String(data: xmlData, encoding: .utf8) {
                                // Basic regex to strip XML tags
                                let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>")
                                let stripped = tagRegex?.stringByReplacingMatches(in: xmlString, range: NSRange(xmlString.startIndex..., in: xmlString), withTemplate: " ")
                                // Decode HTML entities like &#39;
                                let decoded = stripped?
                                    .replacingOccurrences(of: "&#39;", with: "'")
                                    .replacingOccurrences(of: "&quot;", with: "\"")
                                    .replacingOccurrences(of: "&amp;", with: "&")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                metadata.transcript = decoded
                            }
                        }
                    }
                }
            }
        } catch {
            // Ignore transcript fetch errors
        }

        return metadata
    }
}
