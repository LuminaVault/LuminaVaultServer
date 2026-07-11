import FluentKit
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import HummingbirdFluent
import Logging
import LuminaVaultShared

/// P3 — determines what a tenant's connected Hermes actually exposes over
/// HTTP, so clients can gate each settings pane (live / read-only /
/// unsupported) instead of silently writing into a managed container that
/// a BYO user never provisioned.
///
/// Managed tenants (no `user_hermes_config` override) always report
/// `HermesCapabilities.managedDefault` without any network call.
///
/// For BYO tenants it probes the remote `api_server`:
///   - `GET /health` (keyless) → reachability + version
///   - `GET /v1/capabilities` (Bearer) → feature-flag contract
///   - `GET /api/jobs` (Bearer) → jobs probe, because hermes-agent ≥0.18
///     reports `jobs_admin:false` in capabilities yet serves `/api/jobs`
///     (documented discrepancy in docs/hermes-api-server-surface.md).
///
/// Results are cached on the row (`capabilities` JSON + `capabilities_checked_at`)
/// with a TTL so pane loads don't round-trip to the remote box every time.
struct HermesRemoteCapabilitiesService {
    let fluent: Fluent
    let resolver: HermesEndpointResolver
    let probeSession: URLSession
    let logger: Logger
    /// How long a cached probe stays fresh. A remote operator editing
    /// config.yaml + restarting is rare and non-urgent, so an hour is ample.
    let ttl: TimeInterval

    init(
        fluent: Fluent,
        resolver: HermesEndpointResolver,
        probeSession: URLSession = .shared,
        logger: Logger,
        ttl: TimeInterval = 3600
    ) {
        self.fluent = fluent
        self.resolver = resolver
        self.probeSession = probeSession
        self.logger = logger
        self.ttl = ttl
    }

    /// Return the tenant's capabilities, re-probing when the cache is stale
    /// or `force` is set. Never throws on probe failure — an unreachable BYO
    /// box yields a conservative all-`unsupported` view (except chat, which
    /// the resolver already gates), so panes degrade rather than error.
    func capabilities(tenantID: UUID, force: Bool = false, now: Date = Date()) async -> HermesCapabilitiesResponse {
        let resolution: HermesEndpointResolver.Resolution
        do {
            resolution = try await resolver.resolve(tenantID: tenantID)
        } catch {
            // Resolver failure (decrypt/SSRF) — treat as managed so we don't
            // leak a broken BYO row into the pane logic; chat routing surfaces
            // the real error separately.
            return HermesCapabilitiesResponse(capabilities: .managedDefault, checkedAt: nil)
        }

        guard resolution.isUserOverride else {
            return HermesCapabilitiesResponse(capabilities: .managedDefault, checkedAt: nil)
        }

        let row = try? await UserHermesConfig.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .first()

        if !force,
           let row, let cached = row.capabilities,
           let checkedAt = row.capabilitiesCheckedAt,
           now.timeIntervalSince(checkedAt) < ttl,
           let data = cached.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(HermesCapabilities.self, from: data)
        {
            return HermesCapabilitiesResponse(capabilities: decoded, checkedAt: checkedAt)
        }

        let probed = await probe(resolution: resolution)
        // Persist the fresh probe (best-effort — a failed cache write just
        // means the next call re-probes).
        if let row, let encoded = try? JSONEncoder().encode(probed),
           let json = String(data: encoded, encoding: .utf8)
        {
            row.capabilities = json
            row.capabilitiesCheckedAt = now
            try? await row.save(on: fluent.db())
        }
        return HermesCapabilitiesResponse(capabilities: probed, checkedAt: now)
    }

    /// Cheap check (no capability probe) of whether the tenant routes to a
    /// user-hosted Hermes. Used by write paths (SOUL, gateway apply) to
    /// refuse operations that only make sense against the managed container.
    /// Returns false on any resolver error — the write path surfaces the
    /// real routing error separately.
    func isUserOverride(tenantID: UUID) async -> Bool {
        await (try? resolver.resolve(tenantID: tenantID))?.isUserOverride ?? false
    }

    // MARK: - Probe

    private func probe(resolution: HermesEndpointResolver.Resolution) async -> HermesCapabilities {
        let base = resolution.baseURL
        let auth = resolution.authHeader

        let version = await fetchVersion(base: base)
        let flags = await fetchCapabilityFlags(base: base, auth: auth)
        let jobsReachable = await probeJobs(base: base, auth: auth)

        /// Map the remote contract onto our per-domain availability. hermes-agent
        /// keeps SOUL/config/gateways/memory file-on-disk, so those are
        /// structurally unsupported for a live proxy regardless of flags
        /// (see docs/hermes-api-server-surface.md). Chat is always live once the
        /// box is reachable (the resolver already routes it).
        func avail(_ flag: Bool) -> HermesDomainAvailability {
            flag ? .live : .unsupported
        }

        return HermesCapabilities(
            isUserOverride: true,
            remoteVersion: version,
            chat: .live,
            sessions: avail(flags?.sessions ?? false),
            // jobs: trust the live probe over the (buggy) capability flag.
            jobs: jobsReachable ? .live : avail(flags?.jobs ?? false),
            skills: (flags?.skills ?? false) ? .readOnly : .unsupported,
            // Not proxyable — no HTTP write surface on the remote box.
            soul: .unsupported,
            gateways: .unsupported,
            memory: .unsupported,
            providers: .readOnly,
            multimodalIngestion: avail(flags?.multimodalIngestion ?? false),
            ingestionSupportedMimeTypes: flags?.ingestionSupportedMimeTypes,
            ingestionMaxSourceBytes: flags?.ingestionMaxSourceBytes,
            ingestionRemoteSourceURL: flags?.ingestionRemoteSourceURL
        )
    }

    struct CapabilityFlags: Equatable {
        let sessions: Bool
        let jobs: Bool
        let skills: Bool
        let multimodalIngestion: Bool
        let ingestionSupportedMimeTypes: [String]?
        let ingestionMaxSourceBytes: Int64?
        let ingestionRemoteSourceURL: Bool
    }

    private func fetchVersion(base: URL) async -> String? {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        guard
            let (data, response) = try? await probeSession.data(for: req),
            let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["version"] as? String
    }

    private func fetchCapabilityFlags(base: URL, auth: String?) async -> CapabilityFlags? {
        var req = URLRequest(url: base.appendingPathComponent("v1/capabilities"))
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        if let auth {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        guard
            let (data, response) = try? await probeSession.data(for: req),
            let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode)
        else { return nil }
        return Self.parseCapabilities(data)
    }

    /// Parse the `/v1/capabilities` `features` map. Only the flags we gate
    /// panes on are extracted; unknown/false flags default to unsupported.
    static func parseCapabilities(_ data: Data) -> CapabilityFlags? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let features = (obj["features"] as? [String: Any]) ?? obj
        func flag(_ keys: [String]) -> Bool {
            for key in keys where (features[key] as? Bool) == true {
                return true
            }
            return false
        }
        return CapabilityFlags(
            sessions: flag(["session_resources", "sessions", "session_chat"]),
            jobs: flag(["jobs_admin", "jobs"]),
            skills: flag(["skills_api", "skills"]),
            multimodalIngestion: flag(["multimodal_ingestion", "ingestion_api"]),
            ingestionSupportedMimeTypes: features["ingestion_supported_mime_types"] as? [String],
            ingestionMaxSourceBytes: (features["ingestion_max_source_bytes"] as? NSNumber)?.int64Value,
            ingestionRemoteSourceURL: flag(["ingestion_remote_source_url", "remote_source_url"])
        )
    }

    /// hermes-agent under-reports jobs in `/v1/capabilities`; a direct
    /// `GET /api/jobs` is the source of truth. 2xx ⇒ jobs available.
    private func probeJobs(base: URL, auth: String?) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("api/jobs"))
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        if let auth {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        guard
            let (_, response) = try? await probeSession.data(for: req),
            let http = response as? HTTPURLResponse
        else { return false }
        return (200 ..< 300).contains(http.statusCode)
    }
}
