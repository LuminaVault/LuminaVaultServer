import Foundation
import Logging

/// HER-43 (Slice 2) — pulls a user's Raindrop.io bookmarks via the v1 REST API
/// and returns their links for staging. Auth: `Authorization: Bearer <token>`
/// (a test token from app.raindrop.io → Integrations). Collection `0` = all
/// raindrops. Paginates (`perpage` max 50) capped at `maxPages`.
struct RaindropConnector: PluginConnector {
    let binding = "raindrop"
    let http: ConnectorHTTPClient
    let baseURL: URL
    let maxPages: Int
    let logger: Logger

    init(
        http: ConnectorHTTPClient,
        baseURL: URL = URL(string: "https://api.raindrop.io")!,
        maxPages: Int = 20,
        logger: Logger
    ) {
        self.http = http
        self.baseURL = baseURL
        self.maxPages = maxPages
        self.logger = logger
    }

    private static let perPage = 50

    private struct Page: Decodable {
        let items: [Item]
        struct Item: Decodable { let link: String? }
    }

    func fetchURLs(config: [String: String], tenantID: UUID) async throws -> [String] {
        let token = (config["access_token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ConnectorError.missingConfig("access_token") }

        let headers = ["Authorization": "Bearer \(token)"]
        let decoder = JSONDecoder()
        var urls: [String] = []
        var seen = Set<String>()

        for page in 0 ..< maxPages {
            var comps = URLComponents(url: baseURL.appendingPathComponent("/rest/v1/raindrops/0"), resolvingAgainstBaseURL: false)
            comps?.queryItems = [
                URLQueryItem(name: "perpage", value: String(Self.perPage)),
                URLQueryItem(name: "page", value: String(page)),
            ]
            guard let url = comps?.url else { break }

            let resp = try await http.get(url: url, headers: headers)
            switch resp.status {
            case 200: break
            case 401, 403: throw ConnectorError.unauthorized
            default: throw ConnectorError.upstreamFailure(resp.status)
            }

            let decoded = try decoder.decode(Page.self, from: resp.body)
            if decoded.items.isEmpty {
                break
            }
            for item in decoded.items {
                guard let raw = item.link?.trimmingCharacters(in: .whitespacesAndNewlines),
                      raw.hasPrefix("http://") || raw.hasPrefix("https://")
                else { continue }
                if seen.insert(raw).inserted {
                    urls.append(raw)
                }
            }
            if decoded.items.count < Self.perPage {
                break
            }
        }

        logger.info("raindrop connector tenant=\(tenantID) urls=\(urls.count)")
        return urls
    }
}
