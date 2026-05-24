@testable import App
import Foundation
import Testing

/// HER-274 — pure unit tests for the chat-message URL extractor.
/// Deterministic + no DB, so they run regardless of Postgres docker
/// state.
@Suite
struct URLExtractionServiceTests {
    private let svc = URLExtractionService()

    @Test
    func `extracts a single bare URL`() {
        let urls = svc.extract(from: "check out https://news.ycombinator.com today")
        #expect(urls.count == 1)
        #expect(urls[0].raw == "https://news.ycombinator.com")
        #expect(urls[0].normalized == "https://news.ycombinator.com")
    }

    @Test
    func `dedupes the same URL repeated`() {
        let text = "https://example.com/foo and again https://example.com/foo"
        let urls = svc.extract(from: text)
        #expect(urls.count == 1)
        #expect(urls[0].normalized == "https://example.com/foo")
    }

    @Test
    func `dedupes URLs that differ only in fragment`() {
        let text = "https://example.com/post#a vs https://example.com/post#b"
        let urls = svc.extract(from: text)
        #expect(urls.count == 1)
    }

    @Test
    func `keeps URLs that differ in query string`() {
        let text = "https://example.com/q?a=1 vs https://example.com/q?a=2"
        let urls = svc.extract(from: text)
        #expect(urls.count == 2)
    }

    @Test
    func `lowercases scheme and host during normalization`() {
        let urls = svc.extract(from: "HTTPS://EXAMPLE.COM/Path is the same as https://example.com/Path")
        #expect(urls.count == 1)
        #expect(urls[0].normalized == "https://example.com/Path")
    }

    @Test
    func `strips default ports during normalization`() {
        let urls = svc.extract(from: "https://example.com:443/x and https://example.com/x")
        #expect(urls.count == 1)
    }

    @Test
    func `extracts multiple distinct URLs in order`() {
        let text = "first https://a.com then https://b.com finally https://c.com"
        let urls = svc.extract(from: text)
        #expect(urls.count == 3)
        #expect(urls.map(\.normalized) == ["https://a.com", "https://b.com", "https://c.com"])
    }

    @Test
    func `drops non-HTTP schemes`() {
        let urls = svc.extract(from: "ftp://example.com/x and mailto:a@b.com")
        #expect(urls.isEmpty)
    }

    @Test
    func `drops non-public hosts via URLEnricherGuard`() {
        let urls = svc.extract(from: "internal http://localhost:8080/admin or http://192.168.1.1")
        #expect(urls.isEmpty)
    }

    @Test
    func `returns empty for empty text`() {
        #expect(svc.extract(from: "").isEmpty)
    }

    @Test
    func `respects max URL cap`() {
        let baseURLs = (0 ..< URLExtractionService.maxURLsPerExtraction + 10)
            .map { "https://example\($0).com" }
        let text = baseURLs.joined(separator: " ")
        let urls = svc.extract(from: text)
        #expect(urls.count == URLExtractionService.maxURLsPerExtraction)
    }
}
