import Foundation
import Logging

/// The `news-ticker` plugin reuses the connector capability for its
/// install / enable / disable / config lifecycle, but it is a strip on Home,
/// not an import source: a "sync" stages nothing. `fetchURLs` therefore
/// returns nothing, so an accidental sync is a harmless no-op that only
/// stamps `lastSyncAt`. The headlines themselves are served by
/// `NewsTickerService` from the cluster's shared feed aggregator.
struct NewsTickerConnector: PluginConnector {
    let binding = "news-ticker"
    let logger: Logger

    func fetchURLs(config _: [String: String], tenantID: UUID) async throws -> [String] {
        logger.debug("news-ticker connector sync is a no-op tenant=\(tenantID)")
        return []
    }
}
