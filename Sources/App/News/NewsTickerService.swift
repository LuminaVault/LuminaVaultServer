import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

/// What the ticker needs to know about a tenant's `news-ticker` install.
struct NewsTickerInstallState: Sendable, Equatable {
    let enabled: Bool
    let config: [String: String]
}

/// The slice of `PluginService` the ticker reads. A protocol so the service
/// is testable without a database.
protocol NewsTickerInstalls: Sendable {
    /// Nil when the plugin is not installed for this tenant.
    func newsTickerInstall(tenantID: UUID) async throws -> NewsTickerInstallState?
}

/// Serves the Home strip for the first-party `news-ticker` plugin: curated
/// general-news feeds plus whatever the tenant configured, read in one call
/// from the cluster's shared feed aggregator (platform/infra/docs/feeds.md)
/// and cached per tenant for a minute. Headline, source, time, link — never a
/// body.
struct NewsTickerService: Sendable {
    enum ErrorCode: String {
        case notInstalled = "plugin_not_installed"
        case disabled = "plugin_disabled"
        case notConfigured = "news_ticker_not_configured"
    }

    let baseURL: String
    let curatedFeeds: [String]
    let http: any ConnectorHTTPClient
    let installs: any NewsTickerInstalls
    let logger: Logger
    let maxUserFeeds: Int
    private let cache: NewsTickerCache

    /// The aggregator caps one call at 25 feeds.
    static let maxFeedsPerCall = 25

    init(
        baseURL: String,
        curatedFeeds: [String],
        http: any ConnectorHTTPClient,
        installs: any NewsTickerInstalls,
        logger: Logger,
        maxUserFeeds: Int = 10,
        cacheTTL: TimeInterval = 60
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.curatedFeeds = curatedFeeds
        self.http = http
        self.installs = installs
        self.logger = logger
        self.maxUserFeeds = maxUserFeeds
        cache = NewsTickerCache(ttl: cacheTTL)
    }

    var isConfigured: Bool {
        !baseURL.isEmpty
    }

    func ticker(tenantID: UUID, limit: Int) async throws -> NewsTickerResponse {
        guard isConfigured else {
            throw HTTPError(.serviceUnavailable, message: ErrorCode.notConfigured.rawValue)
        }
        guard let install = try await installs.newsTickerInstall(tenantID: tenantID) else {
            throw HTTPError(.notFound, message: ErrorCode.notInstalled.rawValue)
        }
        guard install.enabled else {
            throw HTTPError(.conflict, message: ErrorCode.disabled.rawValue)
        }
        let clamped = min(max(limit, 1), 100)
        let feeds = Self.feedList(curated: curatedFeeds, user: Self.userFeeds(from: install.config, max: maxUserFeeds))
        let now = Date()
        guard !feeds.isEmpty else {
            return NewsTickerResponse(items: [], stale: false, generatedAt: now)
        }
        let key = "\(tenantID)|\(clamped)|" + feeds.joined(separator: "\n")
        if let cached = await cache.get(key, now: now) {
            return cached
        }
        let response = try await fetch(feeds: feeds, limit: clamped, now: now)
        await cache.set(key, response, now: now)
        return response
    }

    private func fetch(feeds: [String], limit: Int, now: Date) async throws -> NewsTickerResponse {
        var components = URLComponents(string: baseURL + "/v1/items")
        components?.queryItems = [
            URLQueryItem(name: "feeds", value: feeds.joined(separator: ",")),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components?.url else {
            throw HTTPError(.internalServerError, message: "invalid feeds base url")
        }
        let resp = try await http.get(url: url, headers: ["Accept": "application/feed+json, application/json"])
        guard resp.status == 200 else {
            logger.warning("news ticker: aggregator returned \(resp.status)")
            throw HTTPError(.badGateway, message: "feeds_unavailable")
        }
        let doc = try JSONFeedDocument.decode(from: resp.body)
        return NewsTickerResponse(
            items: doc.items.map { item in
                NewsTickerItemDTO(
                    id: item.id, title: item.title, url: item.url, source: item.feeds.sourceName,
                    sourceUrl: item.feeds.sourceUrl, publishedAt: item.datePublished
                )
            },
            stale: !(doc.feeds?.stale.isEmpty ?? true),
            generatedAt: doc.feeds?.generatedAt ?? now
        )
    }

    /// The tenant's own feeds from the install config: comma- or
    /// newline-separated, trimmed, public http(s) only, deduped, capped.
    /// A private or malformed address is dropped, not an error: the strip
    /// must still render for everyone else's feeds.
    static func userFeeds(from config: [String: String], max: Int) -> [String] {
        let raw = config["feed_urls"] ?? ""
        var seen = Set<String>()
        var out: [String] = []
        for part in raw.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let url = URL(string: trimmed), URLEnricherGuard.isPublic(url) else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
            if out.count >= max {
                break
            }
        }
        return out
    }

    /// Curated first, then the tenant's, deduped, capped at one aggregator call.
    static func feedList(curated: [String], user: [String]) -> [String] {
        var seen = Set<String>()
        return (curated + user)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(maxFeedsPerCall)
            .map(\.self)
    }
}

/// JSON Feed 1.1 as served by the aggregator, including its `_feeds`
/// extension. Only headline fields; bodies are never sent and would not be
/// kept.
struct JSONFeedDocument: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let id: String
        let url: String?
        let title: String
        let datePublished: Date
        let feeds: Ext

        struct Ext: Decodable, Sendable {
            let sourceName: String
            let sourceUrl: String?
            let feedUrl: String

            enum CodingKeys: String, CodingKey {
                case sourceName = "source_name"
                case sourceUrl = "source_url"
                case feedUrl = "feed_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, url, title
            case datePublished = "date_published"
            case feeds = "_feeds"
        }
    }

    struct Ext: Decodable, Sendable {
        let warming: [String]
        let stale: [String]
        let generatedAt: Date?

        enum CodingKeys: String, CodingKey {
            case warming, stale
            case generatedAt = "generated_at"
        }
    }

    let items: [Item]
    let feeds: Ext?

    enum CodingKeys: String, CodingKey {
        case items
        case feeds = "_feeds"
    }

    static func decode(from data: Data) throws -> JSONFeedDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unparseable date \(raw)"))
        }
        return try decoder.decode(JSONFeedDocument.self, from: data)
    }
}

private struct NewsTickerCacheEntry: Sendable {
    let response: NewsTickerResponse
    let expires: Date
}

/// Per-tenant TTL cache, bounded so a stream of distinct feed sets cannot
/// grow it without limit.
actor NewsTickerCache {
    private let ttl: TimeInterval
    private var entries: [String: NewsTickerCacheEntry] = [:]
    private let maxEntries = 512

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func get(_ key: String, now: Date) -> NewsTickerResponse? {
        guard let entry = entries[key], entry.expires > now else { return nil }
        return entry.response
    }

    func set(_ key: String, _ response: NewsTickerResponse, now: Date) {
        if entries.count >= maxEntries {
            entries = entries.filter { $0.value.expires > now }
            if entries.count >= maxEntries {
                entries.removeAll()
            }
        }
        entries[key] = NewsTickerCacheEntry(response: response, expires: now.addingTimeInterval(ttl))
    }
}
