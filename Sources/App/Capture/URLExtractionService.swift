import Foundation

/// HER-274 — pulls unique HTTP(S) URLs out of chat text so the auto-
/// save-link post-processor can capture each one. Uses a portable
/// `NSRegularExpression` pattern (rather than Darwin-only
/// `NSDataDetector`) so it compiles on swift-corelibs-foundation and
/// CI's Linux test job. The pattern handles pasted-with-trailing-paren,
/// inline-in-markdown, and bare-URL inputs.
///
/// Output is order-preserving + deduplicated by **normalized URL**:
///   - lowercased scheme + host
///   - default port stripped
///   - trailing `/` after host-only path stripped
///   - fragment dropped
///   - query string preserved verbatim
///
/// Non-public hosts (RFC 1918, localhost, link-local) are filtered
/// out via the existing `URLEnricherGuard.isPublic` check so the
/// chat path can't be tricked into capturing internal links.
struct URLExtractionService {
    /// Hard cap so a single chat turn full of URLs can't fan out
    /// hundreds of capture writes. Caller still gets the first N.
    static let maxURLsPerExtraction = 32

    struct ExtractedURL: Equatable {
        let raw: String
        let normalized: String
    }

    func extract(from text: String) -> [ExtractedURL] {
        guard !text.isEmpty else { return [] }
        let pattern = #"(?i)https?://[^\s()<>]+(?:\([^\s()<>]+\)|[^\s`!()\[\]{};:'".,<>?«»“”‘’])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        var seen: Set<String> = []
        var out: [ExtractedURL] = []
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let urlString = String(text[matchRange])
            guard let url = URL(string: urlString) else { continue }
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            guard URLEnricherGuard.isPublic(url) else { continue }
            let normalized = Self.normalize(url)
            if seen.insert(normalized).inserted {
                out.append(ExtractedURL(raw: url.absoluteString, normalized: normalized))
                if out.count >= Self.maxURLsPerExtraction { break }
            }
        }
        return out
    }

    /// Dedupe-only normalization. Returns a stable form for the
    /// equality check inside `extract`; the raw matched substring is
    /// what's persisted to the vault so the user sees what they
    /// pasted.
    static func normalize(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        let scheme = components?.scheme?.lowercased() ?? "http"
        let host = components?.host?.lowercased() ?? ""
        var path = components?.path ?? ""
        if path == "/" { path = "" }
        var portFragment = ""
        if let port = components?.port {
            let defaultPort = (scheme == "https") ? 443 : 80
            if port != defaultPort {
                portFragment = ":\(port)"
            }
        }
        var query = ""
        if let q = components?.query, !q.isEmpty {
            query = "?\(q)"
        }
        return "\(scheme)://\(host)\(portFragment)\(path)\(query)"
    }
}
