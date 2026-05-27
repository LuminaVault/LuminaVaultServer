import Foundation

/// HER-240 / spec ticket #4 — extract HTTP(S) URLs from chat message
/// content. Caps at 5 URLs per message to bound enrichment cost and
/// prevent prompt-injection attacks that bury dozens of links in one
/// message.
enum URLExtractor {
    static let maxURLsPerMessage = 5

    private static let pattern = #"https?://[^\s)>\]]+"#

    /// Extracts up to `maxURLsPerMessage` distinct URLs preserving
    /// first-occurrence order. Trailing punctuation (`.,;:!?`) is stripped
    /// because URLs at end-of-sentence often pick up trailing characters.
    static func extract(from content: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: range)

        var seen = Set<String>()
        var urls: [URL] = []
        for match in matches {
            guard let r = Range(match.range, in: content) else { continue }
            var raw = String(content[r])
            while let last = raw.last, ".,;:!?\"'".contains(last) {
                raw.removeLast()
            }
            if seen.contains(raw) { continue }
            seen.insert(raw)
            guard let url = URL(string: raw), url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" else {
                continue
            }
            urls.append(url)
            if urls.count >= maxURLsPerMessage { break }
        }
        return urls
    }
}
