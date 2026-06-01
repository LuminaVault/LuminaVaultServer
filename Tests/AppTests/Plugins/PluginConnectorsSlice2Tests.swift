@testable import App
import Foundation
import Logging
import LuminaVaultShared
import Testing

// HER-43 Slice 2 — RSS + Raindrop connectors. Pure-logic / stubbed-HTTP, no
// DB, so they avoid the AsyncKit teardown SIGILL (HER-310).

/// Fixed-response stub: returns the same status/body for every GET.
private struct FixedHTTP: ConnectorHTTPClient {
    let status: Int
    let body: Data
    func get(url _: URL, headers _: [String: String]) async throws -> ConnectorHTTPResponse {
        ConnectorHTTPResponse(status: status, body: body)
    }
}

@Suite("Plugin catalog slice 2")
struct PluginCatalogSlice2Tests {
    @Test
    func `rss + raindrop are in the catalog with the right field kinds`() {
        let rss = PluginCatalog.entry(slug: "rss")
        #expect(rss?.binding == "rss")
        #expect(rss?.dto.configFields.contains { $0.key == "feed_url" && $0.kind == .url } == true)

        let raindrop = PluginCatalog.entry(slug: "raindrop")
        #expect(raindrop?.binding == "raindrop")
        #expect(raindrop?.dto.configFields.contains { $0.key == "access_token" && $0.kind == .secret } == true)

        // All connector slugs surface under the connector category, sorted.
        let slugs = PluginCatalog.catalog(category: .connector).map(\.slug)
        #expect(slugs == ["raindrop", "readwise", "rss"])
    }
}

@Suite("RSS connector")
struct RSSConnectorTests {
    @Test
    func `extractLinks parses RSS <link> + Atom href, dedupes, drops non-http`() {
        let xml = """
        <rss><channel>
          <link>https://blog.example.com/</link>
          <item><link>https://blog.example.com/a</link></item>
          <item><link>https://blog.example.com/a</link></item>
          <entry><link rel="alternate" href="https://blog.example.com/b"/></entry>
          <item><link>ftp://nope/x</link></item>
        </channel></rss>
        """
        #expect(RSSConnector.extractLinks(xml) == [
            "https://blog.example.com/",
            "https://blog.example.com/a",
            "https://blog.example.com/b",
        ])
    }

    private func connector(status: Int, xml: String) -> RSSConnector {
        RSSConnector(http: FixedHTTP(status: status, body: Data(xml.utf8)), logger: Logger(label: "test"))
    }

    @Test
    func `fetchURLs returns links for a public feed`() async throws {
        let c = connector(status: 200, xml: "<rss><channel><item><link>https://example.com/a</link></item></channel></rss>")
        let urls = try await c.fetchURLs(config: ["feed_url": "https://example.com/feed.xml"], tenantID: UUID())
        #expect(urls == ["https://example.com/a"])
    }

    @Test
    func `missing feed_url throws missingConfig`() async {
        let c = connector(status: 200, xml: "")
        await #expect(throws: ConnectorError.missingConfig("feed_url")) {
            try await c.fetchURLs(config: [:], tenantID: UUID())
        }
    }

    @Test
    func `non-public feed_url is rejected as invalidConfig (SSRF guard)`() async {
        let c = connector(status: 200, xml: "")
        await #expect(throws: ConnectorError.invalidConfig("feed_url")) {
            try await c.fetchURLs(config: ["feed_url": "http://169.254.169.254/latest/meta-data/"], tenantID: UUID())
        }
        await #expect(throws: ConnectorError.invalidConfig("feed_url")) {
            try await c.fetchURLs(config: ["feed_url": "http://localhost:8080/feed"], tenantID: UUID())
        }
    }
}

@Suite("Raindrop connector")
struct RaindropConnectorTests {
    private func connector(status: Int, json: String) -> RaindropConnector {
        RaindropConnector(
            http: FixedHTTP(status: status, body: Data(json.utf8)),
            maxPages: 3,
            logger: Logger(label: "test"),
        )
    }

    @Test
    func `maps items.link, dedupes, drops non-http; short page stops pagination`() async throws {
        let json = """
        {"items": [
          {"link": "https://example.com/a"},
          {"link": "https://example.com/a"},
          {"link": null},
          {"link": "ftp://nope"},
          {"link": "https://example.com/b"}
        ], "count": 2}
        """
        let urls = try await connector(status: 200, json: json)
            .fetchURLs(config: ["access_token": "tok"], tenantID: UUID())
        #expect(urls == ["https://example.com/a", "https://example.com/b"])
    }

    @Test
    func `missing token throws missingConfig`() async {
        await #expect(throws: ConnectorError.missingConfig("access_token")) {
            try await connector(status: 200, json: "{}").fetchURLs(config: [:], tenantID: UUID())
        }
    }

    @Test
    func `401 maps to unauthorized`() async {
        await #expect(throws: ConnectorError.unauthorized) {
            try await connector(status: 401, json: "{}").fetchURLs(config: ["access_token": "bad"], tenantID: UUID())
        }
    }
}
