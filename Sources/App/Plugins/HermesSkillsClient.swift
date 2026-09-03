import AsyncHTTPClient
import Foundation
import Logging
import LuminaVaultShared
import NIOCore

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
///
/// Audit S-13 — runs on `AsyncHTTPClient` (NIO) rather than `URLSession`,
/// which is the libcurl slow path on Linux.
protocol HermesSkillsClienting: Sendable {
    func installedSkills(baseURL: URL, authHeader: String?) async -> [PluginCatalogEntryDTO]
}

struct HermesSkillsClient: HermesSkillsClienting {
    let http: any HermesHTTPExecuting
    let logger: Logger
    let timeout: TimeAmount
    static let bodyCap = 2 * 1024 * 1024

    init(http: any HermesHTTPExecuting = AsyncHTTPClientHermesHTTP(), logger: Logger, timeout: TimeAmount = .seconds(5)) {
        self.http = http
        self.logger = logger
        self.timeout = timeout
    }

    func installedSkills(baseURL: URL, authHeader: String?) async -> [PluginCatalogEntryDTO] {
        let url = baseURL.appendingPathComponent("v1").appendingPathComponent("skills")
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        request.headers.add(name: "Accept", value: "application/json")
        if let authHeader, !authHeader.isEmpty {
            request.headers.add(name: "Authorization", value: authHeader)
        }
        do {
            let response = try await http.execute(request, timeout: timeout, maxBodyBytes: Self.bodyCap)
            guard response.isSuccess else {
                logger.debug("hermes /v1/skills non-2xx", metadata: ["status": "\(response.status)"])
                return []
            }
            return SkillPluginCatalog.parseHermesSkills(response.data)
        } catch {
            logger.debug("hermes /v1/skills fetch failed: \(Logger.redact(String(describing: error)))")
            return []
        }
    }
}
