@testable import App
import Foundation
import Testing

struct URLEnricherGuardTests {
    @Test(arguments: [
        "http://localhost/admin",
        "http://127.0.0.1:5432",
        "http://10.0.0.1/",
        "http://192.168.1.10/api",
        "http://169.254.169.254/latest/meta-data/",
        "http://172.16.0.1/",
        "http://172.31.255.255/",
        "http://0.0.0.0/",
        "http://[::1]/",
        "http://[fc00::1]/",
        "http://[fe80::1]/",
        "http://metadata.google.internal/",
        "http://server.internal/",
        "http://printer.local/",
        "ftp://example.com/",
        "file:///etc/passwd",
        "javascript:alert(1)",
    ])
    func `private and non-http urls are rejected`(raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(URLEnricherGuard.isPublic(url) == false, "expected reject for \(raw)")
    }

    @Test(arguments: [
        "https://youtube.com/watch?v=abc",
        "https://www.youtube.com/watch?v=abc",
        "https://youtu.be/abc",
        "https://x.com/jack/status/20",
        "https://twitter.com/jack/status/20",
        "https://example.com/page",
        "http://172.32.0.1/",
        "http://172.15.0.1/",
    ])
    func `public hosts pass`(raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(URLEnricherGuard.isPublic(url) == true, "expected accept for \(raw)")
    }

    @Test
    func `youtube enricher routes only youtube hosts`() throws {
        let yt = YouTubeEnricher()
        #expect(try yt.canHandle(url: #require(URL(string: "https://www.youtube.com/watch?v=x"))))
        #expect(try yt.canHandle(url: #require(URL(string: "https://youtu.be/x"))))
        #expect(try !yt.canHandle(url: #require(URL(string: "https://example.com"))))
    }

    @Test
    func `x enricher routes twitter and x hosts`() throws {
        let x = XEnricher()
        #expect(try x.canHandle(url: #require(URL(string: "https://twitter.com/u/status/1"))))
        #expect(try x.canHandle(url: #require(URL(string: "https://x.com/u/status/1"))))
        #expect(try !x.canHandle(url: #require(URL(string: "https://example.com"))))
    }

    @Test
    func `generic og enricher is the catch all`() throws {
        let og = GenericOGEnricher()
        #expect(try og.canHandle(url: #require(URL(string: "https://example.com"))))
        #expect(try og.canHandle(url: #require(URL(string: "https://github.com"))))
    }
}
