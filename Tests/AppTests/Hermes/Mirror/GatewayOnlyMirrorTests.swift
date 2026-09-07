@testable import App
import Foundation
import Logging
import LuminaVaultShared
import Testing

/// A BYO tenant who linked only their gateway.
///
/// That is every iOS user: the app writes `base_url` + `auth_header` and has
/// no screen for the dashboard pair at all. The mirror used to require the
/// dashboard, so those tenants silently fell through to the managed
/// filesystem transport rooted on *our* disk — an empty `skills/` and no
/// `cron/jobs.json` — and reported `lastStatus: .ok`, zero counts, no error.
///
/// It never needed the dashboard for these reads: the gateway serves
/// `/v1/skills`, `/api/jobs` and `/api/sessions` with the key we already hold.
/// Hermes refuses a static dashboard bearer on any non-loopback bind, so for
/// most self-hosters the gateway is the *only* readable source.
struct GatewayOnlyMirrorTests {
    private static let logger = Logger(label: "test.mirror.gateway-only")
    private static let gatewayURL = URL(string: "http://100.105.117.67:8642")!

    /// The real skills client over the stub HTTP, so the wire parser is
    /// exercised rather than mocked past.
    private static func transport(http: StubHermesHTTP) -> RemoteHermesTransport {
        RemoteHermesTransport(
            gatewayBaseURL: gatewayURL,
            gatewayAuthHeader: "Bearer gateway-key",
            skillsClient: HermesSkillsClient(http: http, logger: logger),
            gateway: HermesGatewayReadClient(
                baseURL: gatewayURL,
                authHeader: "Bearer gateway-key",
                http: http,
                logger: logger
            ),
            dashboard: nil,
            logger: logger
        )
    }

    @Test
    func `skills come from the gateway when there is no dashboard`() async throws {
        let http = StubHermesHTTP()
        http.respond("GET", "/v1/skills", json: #"""
        {"skills":[
          {"name":"kb-compile","description":"Compile raw into wiki"},
          {"name":"brandkit","description":"Brand assets"}
        ]}
        """#)
        let skills = try await Self.transport(http: http).listSkills()
        // The catalog parser title-cases the slug and sorts by display name.
        #expect(skills.map(\.name) == ["Brandkit", "Kb Compile"])
        #expect(skills.first(where: { $0.name == "Kb Compile" })?.description == "Compile raw into wiki")
    }

    @Test
    func `jobs come from the gateway api jobs route`() async throws {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/jobs", json: #"""
        {"jobs":[
          {"id":"digest","name":"Daily Digest","schedule":"0 9 * * *","prompt":"summarise","enabled":true},
          {"id":"compile","name":"Nightly compile","schedule":"0 3 * * *","prompt":"kb-compile","enabled":true}
        ]}
        """#)
        let jobs = try await Self.transport(http: http).listJobs()
        #expect(jobs.map(\.id) == ["digest", "compile"])
        #expect(jobs.first?.schedule == "0 9 * * *")
    }

    @Test
    func `sessions come from the gateway api sessions route`() async throws {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/sessions", json: #"""
        {"sessions":[{"id":"s1","title":"Planning","message_count":12,"updated_at":"2026-09-01T10:00:00Z"}],"total":1}
        """#)
        let page = try await Self.transport(http: http).listSessions(offset: 0, limit: 50)
        #expect(page.sessions.map(\.id) == ["s1"])
    }

    /// Writes have no gateway equivalent — cron mutations and filesystem
    /// access exist only on the dashboard. They must fail with the error that
    /// names the real constraint, not look like a transport bug.
    @Test
    func `dashboard-only operations fail with the auth-mode error`() async throws {
        let transport = Self.transport(http: StubHermesHTTP())
        await #expect(throws: HermesMirrorTransportError.dashboardAuthModeUnsupported) {
            try await transport.mkdir(path: "/home/hermes/kb")
        }
        await #expect(throws: HermesMirrorTransportError.dashboardAuthModeUnsupported) {
            try await transport.deleteJob(id: "digest")
        }
    }

    /// Reachability should reflect the gateway we do have rather than
    /// claiming the box is unreachable because no dashboard is linked.
    @Test
    func `status reports reachable from the gateway alone`() async throws {
        let status = try await Self.transport(http: StubHermesHTTP()).status()
        #expect(status.reachable)
    }
}
