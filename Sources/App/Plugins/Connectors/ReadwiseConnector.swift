import Foundation
import Logging

/// HER-43 (Slice 1) — pulls the source articles behind a user's Readwise
/// highlights via the v2 export API and returns their `source_url`s for
/// staging. Books and manually-added highlights have no public URL and are
/// skipped (only http(s) sources flow into the link pipeline).
///
/// Auth: `Authorization: Token <access_token>` (Readwise convention, not
/// Bearer). Paginates via `nextPageCursor`, capped at `maxPages` so a huge
/// library can't make one sync unbounded.
struct ReadwiseConnector: PluginConnector {
    let binding = "readwise"
    let http: ConnectorHTTPClient
    let baseURL: URL
    let maxPages: Int
    let logger: Logger

    init(
        http: ConnectorHTTPClient,
        baseURL: URL = URL(string: "https://readwise.io")!,
        maxPages: Int = 10,
        logger: Logger,
    ) {
        self.http = http
        self.baseURL = baseURL
        self.maxPages = maxPages
        self.logger = logger
    }

    private struct ExportPage: Decodable {
        let nextPageCursor: String?
        let results: [Result]
        struct Result: Decodable {
            let sourceURL: String?
            enum CodingKeys: String, CodingKey { case sourceURL = "source_url" }
        }
    }

    func fetchURLs(config: [String: String], tenantID: UUID) async throws -> [String] {
        let token = (config["access_token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ConnectorError.missingConfig("access_token") }

        let headers = ["Authorization": "Token \(token)"]
        let decoder = JSONDecoder()
        var urls: [String] = []
        var seen = Set<String>()
        var cursor: String?

        for _ in 0 ..< maxPages {
            var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v2/export/"), resolvingAgainstBaseURL: false)
            if let cursor { comps?.queryItems = [URLQueryItem(name: "pageCursor", value: cursor)] }
            guard let url = comps?.url else { break }

            let resp = try await http.get(url: url, headers: headers)
            switch resp.status {
            case 200: break
            case 401, 403: throw ConnectorError.unauthorized
            default: throw ConnectorError.upstreamFailure(resp.status)
            }

            let page = try decoder.decode(ExportPage.self, from: resp.body)
            for result in page.results {
                guard let raw = result.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                      raw.hasPrefix("http://") || raw.hasPrefix("https://")
                else { continue }
                if seen.insert(raw).inserted { urls.append(raw) }
            }

            guard let next = page.nextPageCursor, !next.isEmpty else { break }
            cursor = next
        }

        logger.info("readwise connector tenant=\(tenantID) urls=\(urls.count)")
        return urls
    }
}
