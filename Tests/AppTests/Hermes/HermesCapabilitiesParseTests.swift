@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// P3 — the `/v1/capabilities` feature-flag parser that drives BYO-Hermes
/// pane gating.
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct HermesCapabilitiesParseTests {
    @Test("parses the hermes-agent 0.18 features map")
    func parsesFeaturesMap() {
        // Shape from docs/hermes-api-server-surface.md (live VPS response).
        let body = """
        {"features":{
            "chat_completions":true,"responses_api":true,
            "session_resources":true,"skills_api":true,
            "admin_config_rw":false,"jobs_admin":false,"memory_write_api":false
        }}
        """.data(using: .utf8)!
        let flags = HermesRemoteCapabilitiesService.parseCapabilities(body)
        #expect(flags?.sessions == true)
        #expect(flags?.skills == true)
        // jobs_admin is false in the flags (the /api/jobs probe overrides this
        // at runtime — see the service), so the flag itself reads false.
        #expect(flags?.jobs == false)
    }

    @Test("accepts a flat map without a features envelope")
    func parsesFlatMap() {
        let body = #"{"sessions":true,"skills_api":true,"jobs":true}"#.data(using: .utf8)!
        let flags = HermesRemoteCapabilitiesService.parseCapabilities(body)
        #expect(flags?.sessions == true)
        #expect(flags?.skills == true)
        #expect(flags?.jobs == true)
    }

    @Test("unknown flags default to false")
    func unknownFlagsFalse() throws {
        let flags = try HermesRemoteCapabilitiesService.parseCapabilities(#require(#"{"features":{}}"#.data(using: .utf8)))
        #expect(flags == HermesRemoteCapabilitiesService.CapabilityFlags(sessions: false, jobs: false, skills: false))
    }

    @Test("garbage body returns nil")
    func garbageNil() {
        #expect(HermesRemoteCapabilitiesService.parseCapabilities(Data("nope".utf8)) == nil)
    }

    @Test("managedDefault reports every domain as managed")
    func managedDefaultAllManaged() {
        let c = HermesCapabilities.managedDefault
        #expect(c.isUserOverride == false)
        for domain in [c.chat, c.sessions, c.jobs, c.skills, c.soul, c.gateways, c.memory, c.providers] {
            #expect(domain == .managed)
        }
    }
}
