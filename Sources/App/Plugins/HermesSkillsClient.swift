import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Logging
import LuminaVaultShared

/// HER-43 (Slice 3a) — read-only client for the tenant's Hermes agent skills.
///
/// Hermes' API server exposes `GET /v1/skills` (see
/// https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server).
/// We surface what's installed in the user's Hermes as read-only catalog
/// entries. Hub *install* is CLI-only upstream (`hermes skills install`) and
/// lands in Slice 3b via the management plane — not here.
///
/// Best-effort: any failure (no resolution, unreachable, unauthorized, odd
/// body) yields an empty list rather than throwing, so the plugin store
/// degrades gracefully when Hermes is down.
protocol HermesSkillsClienting: Sendable {
    func installedSkills(baseURL: URL, authHeader: String?) async -> [PluginCatalogEntryDTO]
}

struct HermesSkillsClient: HermesSkillsClienting {
    let session: URLSession
    let logger: Logger
    let timeout: TimeInterval

    init(session: URLSession = .shared, logger: Logger, timeout: TimeInterval = 5) {
        self.session = session
        self.logger = logger
        self.timeout = timeout
    }

    func installedSkills(baseURL: URL, authHeader: String?) async -> [PluginCatalogEntryDTO] {
        let url = baseURL.appendingPathComponent("v1").appendingPathComponent("skills")
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        if let authHeader, !authHeader.isEmpty {
            req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                logger.debug("hermes /v1/skills non-2xx")
                return []
            }
            return SkillPluginCatalog.parseHermesSkills(data)
        } catch {
            logger.debug("hermes /v1/skills fetch failed: \(error)")
            return []
        }
    }
}
