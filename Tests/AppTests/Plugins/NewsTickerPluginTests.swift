@testable import App
import Foundation
import Hummingbird
import Logging
import LuminaVaultShared
import Testing

// First-party `news-ticker` plugin. Pure-logic / stubbed-HTTP, no DB (the
// install lookup is a protocol), so these avoid the AsyncKit teardown SIGILL.

private struct FixedHTTP: ConnectorHTTPClient {
    let status: Int
    let body: Data
    func get(url _: URL, headers _: [String: String]) async throws -> ConnectorHTTPResponse {
        ConnectorHTTPResponse(status: status, body: body)
    }
}

private final class CountingHTTP: ConnectorHTTPClient, @unchecked Sendable {
    let body: Data
    private(set) var calls = 0
    private(set) var lastURL: URL?
    init(body: Data) {
        self.body = body
    }

    func get(url: URL, headers _: [String: String]) async throws -> ConnectorHTTPResponse {
        calls += 1
        lastURL = url
        return ConnectorHTTPResponse(status: 200, body: body)
    }
}

private struct StubInstalls: NewsTickerInstalls {
    let state: NewsTickerInstallState?
    func newsTickerInstall(tenantID _: UUID) async throws -> NewsTickerInstallState? {
        state
    }
}

private let fixture = Data("""
{"version":"https://jsonfeed.org/version/1.1","title":"Merged timeline","items":[
 {"id":"a","url":"https://bbc.example/a","title":"Ceasefire talks resume","date_published":"2026-09-17T11:00:00Z","_feeds":{"source_name":"BBC News","source_url":"https://www.bbc.co.uk","feed_url":"https://feeds.bbci.co.uk/news/rss.xml"}},
 {"id":"b","url":"https://npr.example/b","title":"Markets open higher","date_published":"2026-09-17T10:30:00.250Z","_feeds":{"source_name":"NPR","feed_url":"https://feeds.npr.org/1001/rss.xml"}}],
 "_feeds":{"warming":[],"stale":["https://feeds.npr.org/1001/rss.xml"],"generated_at":"2026-09-17T12:00:00Z"}}
""".utf8)

private func service(http: any ConnectorHTTPClient, state: NewsTickerInstallState?, baseURL: String = "https://feeds.test", curated: [String] = ["https://feeds.bbci.co.uk/news/rss.xml"]) -> NewsTickerService {
    NewsTickerService(baseURL: baseURL, curatedFeeds: curated, http: http, installs: StubInstalls(state: state), logger: Logger(label: "test"))
}

@Suite("News ticker plugin", .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct NewsTickerPluginTests {
    @Test
    func `catalog carries news-ticker as a featured ui plugin bound to a no-op connector`() async throws {
        let entry = PluginCatalog.entry(slug: "news-ticker")
        #expect(entry?.binding == "news-ticker")
        #expect(entry?.dto.category == .ui)
        #expect(entry?.dto.capabilityKind == .connector)
        #expect(entry?.featured == true)
        #expect(entry?.dto.configFields.contains { $0.key == "feed_urls" && $0.kind == .text && !$0.isRequired } == true)
        let connector = NewsTickerConnector(logger: Logger(label: "test"))
        #expect(try await connector.fetchURLs(config: ["feed_urls": "https://x/rss"], tenantID: UUID()).isEmpty)
    }

    @Test
    func `not installed is 404, disabled is 409, unconfigured is 503`() async throws {
        let http = FixedHTTP(status: 200, body: fixture)
        await #expect(throws: HTTPError.self) {
            _ = try await service(http: http, state: nil).ticker(tenantID: UUID(), limit: 10)
        }
        do {
            _ = try await service(http: http, state: nil).ticker(tenantID: UUID(), limit: 10)
        } catch let e as HTTPError {
            #expect(e.status == .notFound)
        }
        do {
            _ = try await service(http: http, state: NewsTickerInstallState(enabled: false, config: [:])).ticker(tenantID: UUID(), limit: 10)
        } catch let e as HTTPError {
            #expect(e.status == .conflict)
        }
        do {
            _ = try await service(http: http, state: NewsTickerInstallState(enabled: true, config: [:]), baseURL: "").ticker(tenantID: UUID(), limit: 10)
        } catch let e as HTTPError {
            #expect(e.status == .serviceUnavailable)
        }
    }

    @Test
    func `maps aggregator items to DTOs, flags stale, caches per tenant`() async throws {
        let http = CountingHTTP(body: fixture)
        let svc = service(http: http, state: NewsTickerInstallState(enabled: true, config: [:]))
        let tenant = UUID()
        let first = try await svc.ticker(tenantID: tenant, limit: 10)
        #expect(first.items.count == 2)
        #expect(first.items[0].title == "Ceasefire talks resume")
        #expect(first.items[0].source == "BBC News")
        #expect(first.items[0].sourceUrl == "https://www.bbc.co.uk")
        #expect(first.items[1].publishedAt.timeIntervalSince1970 == 1_789_641_000.25)
        #expect(first.stale)
        #expect(http.lastURL?.absoluteString.contains("limit=10") == true)
        _ = try await svc.ticker(tenantID: tenant, limit: 10)
        #expect(http.calls == 1)
        _ = try await svc.ticker(tenantID: UUID(), limit: 10)
        #expect(http.calls == 2)
    }

    @Test
    func `user feeds are appended after curated, private and malformed ones dropped, capped`() {
        let user = NewsTickerService.userFeeds(from: ["feed_urls": " https://a.example/rss ,http://10.0.0.1/x, not a url\nhttps://b.example/feed.json,https://a.example/rss "], max: 10)
        #expect(user == ["https://a.example/rss", "https://b.example/feed.json"])
        let capped = NewsTickerService.userFeeds(from: ["feed_urls": (1 ... 15).map { "https://f\($0).example/rss" }.joined(separator: ",")], max: 3)
        #expect(capped.count == 3)
        let merged = NewsTickerService.feedList(curated: ["https://c.example/rss", "https://a.example/rss"], user: user)
        #expect(merged == ["https://c.example/rss", "https://a.example/rss", "https://b.example/feed.json"])
        let many = NewsTickerService.feedList(curated: (1 ... 40).map { "https://f\($0).example/rss" }, user: [])
        #expect(many.count == NewsTickerService.maxFeedsPerCall)
    }

    @Test
    func `aggregator failure is a 502`() async {
        let svc = service(http: FixedHTTP(status: 502, body: Data()), state: NewsTickerInstallState(enabled: true, config: [:]))
        do {
            _ = try await svc.ticker(tenantID: UUID(), limit: 5)
            Issue.record("expected an error")
        } catch let e as HTTPError {
            #expect(e.status == .badGateway)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
