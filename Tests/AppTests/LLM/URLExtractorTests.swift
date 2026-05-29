@testable import App
import Foundation
import Testing

struct URLExtractorTests {
    @Test
    func `extracts single url`() {
        let urls = URLExtractor.extract(from: "Check https://example.com/article")
        #expect(urls.count == 1)
        #expect(urls.first?.absoluteString == "https://example.com/article")
    }

    @Test
    func `extracts multiple distinct urls preserving order`() {
        let urls = URLExtractor.extract(from: "see https://a.com and https://b.com/x")
        #expect(urls.map(\.absoluteString) == ["https://a.com", "https://b.com/x"])
    }

    @Test
    func `dedupes identical urls`() {
        let urls = URLExtractor.extract(from: "https://a.com twice https://a.com")
        #expect(urls.count == 1)
    }

    @Test
    func `caps at 5 urls per message`() {
        let many = (0 ..< 10).map { "https://e\($0).com" }.joined(separator: " ")
        let urls = URLExtractor.extract(from: many)
        #expect(urls.count == 5)
    }

    @Test
    func `strips trailing punctuation`() {
        let urls = URLExtractor.extract(from: "ref https://x.com/path. end")
        #expect(urls.first?.absoluteString == "https://x.com/path")
    }

    @Test
    func `ignores non-http schemes`() {
        let urls = URLExtractor.extract(from: "javascript:alert(1) ftp://x and https://ok.com")
        #expect(urls.count == 1)
        #expect(urls.first?.absoluteString == "https://ok.com")
    }

    @Test
    func `empty input returns empty array`() {
        #expect(URLExtractor.extract(from: "").isEmpty)
        #expect(URLExtractor.extract(from: "no urls here").isEmpty)
    }

    @Test
    func `strips trailing right-paren and bracket`() {
        let urls = URLExtractor.extract(from: "(https://a.com) [https://b.com]")
        let abs = urls.map(\.absoluteString)
        #expect(abs.contains("https://a.com"))
        #expect(abs.contains("https://b.com"))
    }
}
