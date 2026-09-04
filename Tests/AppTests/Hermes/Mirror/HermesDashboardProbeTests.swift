@testable import App
import Foundation
import Logging
import LuminaVaultShared
import Testing

/// Hermes Mirror task 2 — the dashboard capability probe classifies the
/// three auth outcomes and gates every dashboard capability on `bearer`.
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct HermesDashboardProbeTests {
    private static let logger = Logger(label: "test.hermes-probe")

    private func client(_ http: StubHermesHTTP) -> HermesDashboardClient {
        HermesDashboardClient(
            baseURL: "http://127.0.0.1:9119",
            token: "t",
            ssrfGuard: SSRFGuard(allowPrivateRanges: true, requireHTTPS: false, allowTailnetHTTP: true),
            http: http,
            logger: Self.logger
        )
    }

    @Test
    func `bearer mode on a loopback dashboard enables every capability`() async {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/status", json: #"{"version":"0.21.0","auth_required":false}"#)
        http.respond("GET", "/api/fs/default-cwd", json: #"{"cwd":"/home/hermes"}"#)
        http.respond("GET", "/api/skills", json: "[]")
        let probe = await HermesRemoteCapabilitiesService.probeDashboard(client: client(http))
        #expect(probe == HermesDashboardCapabilitiesDTO(reachable: true, authMode: .bearer, skillsWrite: true, cron: true, fs: true, sessions: true, version: "0.21.0", kbVaultPath: nil))
    }

    @Test
    func `gated dashboard answering 401 reports oauth_only with nothing usable`() async {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/status", json: #"{"version":"0.21.0","auth_required":true}"#)
        http.respond("GET", "/api/skills", status: 401, json: #"{"detail":"Unauthorized"}"#)
        let probe = await HermesRemoteCapabilitiesService.probeDashboard(client: client(http))
        #expect(probe.reachable == true)
        #expect(probe.authMode == .oauthOnly)
        #expect(probe.skillsWrite == false)
        #expect(probe.cron == false)
        #expect(probe.fs == false)
        #expect(probe.sessions == false)
    }

    @Test
    func `login redirect reports oauth_only even when status omits auth_required`() async {
        let http = StubHermesHTTP()
        http.respond("GET", "/api/status", json: #"{"version":"0.21.0"}"#)
        http.respond("GET", "/api/skills", status: 302, json: "", headers: [("Location", "/login")])
        let probe = await HermesRemoteCapabilitiesService.probeDashboard(client: client(http))
        #expect(probe.authMode == .oauthOnly)
    }

    @Test
    func `unreachable dashboard reports unreachable`() async {
        let http = StubHermesHTTP()
        http.failure = URLError(.cannotConnectToHost)
        let probe = await HermesRemoteCapabilitiesService.probeDashboard(client: client(http))
        #expect(probe == HermesDashboardCapabilitiesDTO(reachable: false, authMode: .unreachable, skillsWrite: false, cron: false, fs: false, sessions: false))
    }

    @Test
    func `attach keeps every gateway field and adds the dashboard`() {
        let dashboard = HermesDashboardCapabilitiesDTO(reachable: true, authMode: .bearer, skillsWrite: true, cron: true, fs: true, sessions: true)
        let merged = HermesRemoteCapabilitiesService.attach(dashboard: dashboard, to: .managedDefault)
        #expect(merged.isUserOverride == false)
        #expect(merged.chat == .managed)
        #expect(merged.ingestionMaxSourceBytes == HermesCapabilities.managedDefault.ingestionMaxSourceBytes)
        #expect(merged.dashboard == dashboard)
    }

    @Test
    func `cached capabilities without a dashboard field still decode`() throws {
        let legacy = #"{"isUserOverride":true,"chat":"live","sessions":"live","jobs":"live","skills":"read_only","soul":"unsupported","gateways":"unsupported","memory":"unsupported","providers":"read_only"}"#
        let decoded = try JSONDecoder().decode(HermesCapabilities.self, from: Data(legacy.utf8))
        #expect(decoded.dashboard == nil)
        #expect(decoded.skills == .readOnly)
    }
}
