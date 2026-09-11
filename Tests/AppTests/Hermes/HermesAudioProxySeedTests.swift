@testable import App
import Foundation
import Testing

/// Covers the speech configuration seeded into a tenant's Hermes container.
///
/// Two failure modes drive these tests, and both look like success in
/// production:
///
///  1. Omitting `tts.provider` — Hermes treats *any* unrecognised provider
///     name as Edge TTS, which is free, keyless and outside our metering. A
///     tenant would happily synthesise speech we never see or bill.
///  2. Changing the rendering for tenants who have no audio proxy configured.
///     The seed is SHA-256 drift-compared, so a stray byte rewrites
///     `config.yaml` for every existing container on its next restart.
struct HermesAudioProxySeedTests {
    static let proxy = HermesAudioProxySeed(
        baseURL: "https://api.luminavault.app/v1",
        token: "scoped-audio-token"
    )

    // MARK: - config.yaml

    @Test
    func emitsSTTBlockPointedAtTheProxy() {
        let yaml = HermesTenantConfigTemplate.configYAML(
            defaultModel: "hermes-3",
            mnemosyneEnabled: true,
            audioProxy: Self.proxy
        )

        #expect(yaml.contains("stt:"))
        #expect(yaml.contains("provider: openai"))
        #expect(yaml.contains("base_url: \"https://api.luminavault.app/v1\""))
        #expect(yaml.contains("enabled: true"))
    }

    /// The load-bearing one. Hermes' TTS default is Edge — free and unmetered
    /// — and an unknown provider name falls back to it rather than disabling
    /// synthesis. Pinning `openai` at our proxy is the only configuration
    /// that makes spoken replies impossible to produce off-budget.
    @Test
    func pinsTTSProviderSoEdgeTTSCanNeverBeSelected() {
        let yaml = HermesTenantConfigTemplate.configYAML(
            defaultModel: "hermes-3",
            mnemosyneEnabled: true,
            audioProxy: Self.proxy
        )

        #expect(yaml.contains("tts:"))
        #expect(!yaml.contains("provider: edge"))
        // Both blocks name openai; neither may be left to default.
        let providerPins = yaml.components(separatedBy: "provider: openai").count - 1
        #expect(providerPins == 2, "expected stt and tts to each pin provider: openai")
    }

    /// Credentials belong in `.env`, which is not world-readable inside the
    /// container image and is not what operators paste into tickets.
    @Test
    func configYAMLNeverContainsTheCredential() {
        let yaml = HermesTenantConfigTemplate.configYAML(
            defaultModel: "hermes-3",
            mnemosyneEnabled: true,
            audioProxy: Self.proxy
        )
        #expect(!yaml.contains(Self.proxy.token))
    }

    /// Regression guard for every tenant that predates this feature.
    @Test
    func rendersIdenticallyToBeforeWhenNoProxyIsConfigured() {
        let yaml = HermesTenantConfigTemplate.configYAML(
            defaultModel: "hermes-3",
            mnemosyneEnabled: true,
            audioProxy: nil
        )

        #expect(!yaml.contains("stt:"))
        #expect(!yaml.contains("tts:"))
        // The pre-existing content is untouched.
        #expect(yaml.contains("model:"))
        #expect(yaml.contains("allow_all_users: false"))
        #expect(yaml.contains("mcp_servers:"))
    }

    @Test
    func audioAndMnemosyneBlocksCoexist() {
        let yaml = HermesTenantConfigTemplate.configYAML(
            defaultModel: "hermes-3",
            mnemosyneEnabled: true,
            audioProxy: Self.proxy
        )
        #expect(yaml.contains("stt:"))
        #expect(yaml.contains("mcp_servers:"))
        #expect(yaml.contains("memory_enabled: false"))
    }

    @Test
    func audioIsEmittedEvenWhenMnemosyneIsOff() {
        let yaml = HermesTenantConfigTemplate.configYAML(
            defaultModel: "hermes-3",
            mnemosyneEnabled: false,
            audioProxy: Self.proxy
        )
        #expect(yaml.contains("stt:"))
        #expect(!yaml.contains("mcp_servers:"))
    }

    /// The seed is only idempotent if rendering is deterministic — otherwise
    /// the drift check rewrites on every restart and stops meaning anything.
    @Test
    func renderingIsDeterministic() {
        let first = HermesTenantConfigTemplate.configYAML(
            defaultModel: "hermes-3", mnemosyneEnabled: true, audioProxy: Self.proxy
        )
        let second = HermesTenantConfigTemplate.configYAML(
            defaultModel: "hermes-3", mnemosyneEnabled: true, audioProxy: Self.proxy
        )
        #expect(first == second)
    }

    // MARK: - .env

    @Test
    func envCarriesScopedKeyAndBaseURL() {
        let env = HermesTenantConfigTemplate.envFile(
            apiKey: "api-key",
            gateways: [],
            audioProxy: Self.proxy
        )

        #expect(env.contains("VOICE_TOOLS_OPENAI_KEY='scoped-audio-token'"))
        #expect(env.contains("STT_OPENAI_BASE_URL='https://api.luminavault.app/v1'"))
    }

    /// `OPENAI_API_KEY` would be picked up as a general chat provider key.
    /// The audio credential is scoped to `/v1/audio/*` and must not leak into
    /// model routing.
    @Test
    func envDoesNotSetAGeneralOpenAIKey() {
        let env = HermesTenantConfigTemplate.envFile(
            apiKey: "api-key",
            gateways: [],
            audioProxy: Self.proxy
        )
        let lines = env.components(separatedBy: "\n")
        #expect(!lines.contains { $0.hasPrefix("OPENAI_API_KEY=") })
    }

    @Test
    func envOmitsVoiceEntirelyWhenNoProxyIsConfigured() {
        let env = HermesTenantConfigTemplate.envFile(
            apiKey: "api-key",
            gateways: [],
            audioProxy: nil
        )
        #expect(!env.contains("VOICE_TOOLS_OPENAI_KEY"))
        #expect(!env.contains("STT_OPENAI_BASE_URL"))
    }
}
