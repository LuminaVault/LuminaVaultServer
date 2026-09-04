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
/// Hermes Mirror adds a **dashboard** probe (`web_server.py`, `/api/*`) when
/// the row carries a dashboard URL + sealed token: `GET /api/status` for
/// reachability/version/`auth_required`, then `GET /api/skills` with the
/// bearer to learn whether the bearer path works at all (`authMode`). A
/// dashboard behind the OAuth gate reports `oauth_only`, which clients
/// surface as `hermes_dashboard_auth_mode_unsupported` with the
/// loopback-behind-proxy fix. The probe runs for managed tenants too — a
/// tenant can link only the dashboard for cron/mirror while chat stays managed.
///
/// Results are cached on the row (`capabilities` JSON + `capabilities_checked_at`)
/// with a TTL so pane loads don't round-trip to the remote box every time.
struct HermesRemoteCapabilitiesService {
    let fluent: Fluent
    let resolver: HermesEndpointResolver
    let probeSession: URLSession
    let dashboardCredentials: HermesDashboardCredentialStore?
    let dashboardSSRFGuard: SSRFGuard?
    let dashboardHTTP: any HermesHTTPExecuting
    let logger: Logger
    /// How long a cached probe stays fresh. A remote operator editing
    /// config.yaml + restarting is rare and non-urgent, so an hour is ample.
    let ttl: TimeInterval

    init(
        fluent: Fluent,
        resolver: HermesEndpointResolver,
        probeSession: URLSession = .shared,
        dashboardCredentials: HermesDashboardCredentialStore? = nil,
        dashboardSSRFGuard: SSRFGuard? = nil,
        dashboardHTTP: any HermesHTTPExecuting = AsyncHTTPClientHermesHTTP(),
        logger: Logger,
        ttl: TimeInterval = 3600
    ) {
        self.fluent = fluent
        self.resolver = resolver
        self.probeSession = probeSession
        self.dashboardCredentials = dashboardCredentials
        self.dashboardSSRFGuard = dashboardSSRFGuard
        self.dashboardHTTP = dashboardHTTP
        self.logger = logger
        self.ttl = ttl
    }

    /// Return the tenant's capabilities, re-probing when the cache is stale
    /// or `force` is set. Never throws on probe failure — an unreachable BYO
    /// box yields a conservative all-`unsupported` view (except chat, which
    /// the resolver already gates), so panes degrade rather than error.
    func capabilities(tenantID: UUID, force: Bool = false, now: Date = Date()) async -> HermesCapabilitiesResponse {
        let row = try? await UserHermesConfig.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .first()
        let hasDashboard = row.map { ($0.cronDashboardURL ?? "").isEmpty == false } ?? false

        let resolution: HermesEndpointResolver.Resolution?
        do {
            resolution = try await resolver.resolve(tenantID: tenantID)
        } catch {
            // Resolver failure (decrypt/SSRF) — treat as managed so we don't
            // leak a broken BYO row into the pane logic; chat routing surfaces
            // the real error separately.
            resolution = nil
        }

        let isUserOverride = resolution?.isUserOverride ?? false
        guard isUserOverride || hasDashboard else {
            return HermesCapabilitiesResponse(capabilities: .managedDefault, checkedAt: nil)
        }

        if !force,
           let row, let cached = row.capabilities,
           let checkedAt = row.capabilitiesCheckedAt,
           now.timeIntervalSince(checkedAt) < ttl,
           let data = cached.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(HermesCapabilities.self, from: data)
        {
            return HermesCapabilitiesResponse(capabilities: decoded, checkedAt: checkedAt)
        }

        let dashboard: HermesDashboardCapabilitiesDTO? = if let row, hasDashboard {
            await probeDashboard(row: row, tenantID: tenantID)
        } else {
            nil
        }
        let probed: HermesCapabilities = if let resolution, isUserOverride {
            await Self.attach(dashboard: dashboard, to: probe(resolution: resolution))
        } else {
            Self.attach(dashboard: dashboard, to: .managedDefault)
        }
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

    /// Fresh dashboard probe for one tenant (no cache) — used by the mirror
    /// sync so its status always reflects the live auth mode. Nil when the
    /// tenant has no dashboard configured or the sealed token cannot be read.
    func dashboardProbe(tenantID: UUID) async -> HermesDashboardCapabilitiesDTO? {
        guard let row = try? await UserHermesConfig.query(on: fluent.db(), tenantID: tenantID).first() else {
            return nil
        }
        return await probeDashboard(row: row, tenantID: tenantID)
    }

    private func probeDashboard(row: UserHermesConfig, tenantID: UUID) async -> HermesDashboardCapabilitiesDTO? {
        guard let dashboardCredentials, let dashboardSSRFGuard else { return nil }
        let credentials: HermesDashboardCredentialStore.Credentials
        do {
            guard let found = try dashboardCredentials.credentials(from: row, tenantID: tenantID) else { return nil }
            credentials = found
        } catch {
            logger.warning("dashboard token decrypt failed", metadata: ["tenant": .string(tenantID.uuidString)])
            return HermesDashboardCapabilitiesDTO(reachable: false, authMode: .unauthorized, skillsWrite: false, cron: false, fs: false, sessions: false)
        }
        let client = HermesDashboardClient(
            baseURL: credentials.url,
            token: credentials.token,
            ssrfGuard: dashboardSSRFGuard,
            http: dashboardHTTP,
            logger: logger
        )
        return await Self.probeDashboard(client: client)
    }

    /// Pure probe over a dashboard client: status (public) + one protected
    /// call to classify the auth mode. Every capability is gated on `bearer`.
    static func probeDashboard(client: HermesDashboardClient) async -> HermesDashboardCapabilitiesDTO {
        let status: HermesDashboardStatus
        do {
            status = try await client.status()
        } catch {
            return HermesDashboardCapabilitiesDTO(reachable: false, authMode: .unreachable, skillsWrite: false, cron: false, fs: false, sessions: false)
        }
        let authMode = await client.probeAuthMode(authRequired: status.authRequired)
        let usable = authMode == .bearer
        return HermesDashboardCapabilitiesDTO(
            reachable: true,
            authMode: authMode,
            skillsWrite: usable,
            cron: usable,
            fs: usable,
            sessions: usable,
            version: status.version,
            kbVaultPath: nil
        )
    }

    static func attach(dashboard: HermesDashboardCapabilitiesDTO?, to capabilities: HermesCapabilities) -> HermesCapabilities {
        HermesCapabilities(
            isUserOverride: capabilities.isUserOverride,
            remoteVersion: capabilities.remoteVersion,
            chat: capabilities.chat,
            sessions: capabilities.sessions,
            jobs: capabilities.jobs,
            skills: capabilities.skills,
            soul: capabilities.soul,
            gateways: capabilities.gateways,
            memory: capabilities.memory,
            providers: capabilities.providers,
            multimodalIngestion: capabilities.multimodalIngestion,
            ingestionSupportedMimeTypes: capabilities.ingestionSupportedMimeTypes,
            ingestionMaxSourceBytes: capabilities.ingestionMaxSourceBytes,
            ingestionRemoteSourceURL: capabilities.ingestionRemoteSourceURL,
            dashboard: dashboard
        )
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
