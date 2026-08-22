@testable import App
import Configuration
import Foundation
import Logging
import Testing

/// HER-161 — `ProviderRegistry` env-loading + enablement gating.
@Suite(.serialized, .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct ProviderRegistryTests {
    @Test
    func `all seven providers env loadable from config`() async {
        let r = ConfigReader(providers: [InMemoryProvider(values: [
            "llm.provider.anthropic.apiKey": cfg("a-key"),
            "llm.provider.openai.apiKey": cfg("o-key"),
            "llm.provider.gemini.apiKey": cfg("g-key"),
            "llm.provider.together.apiKey": cfg("t-key"),
            "llm.provider.groq.apiKey": cfg("q-key"),
            "llm.provider.fireworks.apiKey": cfg("f-key"),
            "llm.provider.deepseekDirect.apiKey": cfg("d-key"),
        ])])
        let registry = ProviderRegistry.from(reader: r, adapters: [], logger: Logger(label: "test"))
        let enabled = await registry.enabledProviders()
        #expect(Set(enabled) == Set([
            .anthropic, .openai, .gemini, .together, .groq, .fireworks, .deepseekDirect,
        ]))
    }

    /// `secrets/*/llm-fallback.example.yaml` templates a platform-owned
    /// OpenRouter key under `OPENROUTER_FALLBACK_API_KEY`, described there as
    /// the credential apps "fall through to when their own provider is out of
    /// credit, rate limited, or unconfigured". Nothing read it, so sealing that
    /// secret would have left the free lane dark. It is now the last-resort
    /// alias, behind the canonical name and the two legacy spellings.
    @Test
    func `openrouter fallback api key alias enables the provider`() async {
        let r = ConfigReader(providers: [InMemoryProvider(values: [
            "openrouter.fallback_api_key": cfg("fallback-key"),
        ])])
        let registry = ProviderRegistry.from(reader: r, adapters: [], logger: Logger(label: "test"))
        let enabled = await registry.isEnabled(.openRouter)
        let config = await registry.config(for: .openRouter)
        #expect(enabled == true)
        #expect(config?.apiKey == "fallback-key")
    }

    /// `isEnabled` treats a blank key as missing, but alias selection used to
    /// pick the first *non-empty* string — so a canonical key sealed as a stray
    /// space shadowed a perfectly good fallback and silently disabled the
    /// provider, taking the free lane down with it. Blank must mean absent in
    /// both places.
    @Test
    func `a blank canonical key does not shadow a usable alias`() async {
        let r = ConfigReader(providers: [InMemoryProvider(values: [
            "llm.provider.openRouter.apiKey": cfg("   "),
            "openrouter.fallback_api_key": cfg("fallback-key"),
        ])])
        let registry = ProviderRegistry.from(reader: r, adapters: [], logger: Logger(label: "test"))
        let enabled = await registry.isEnabled(.openRouter)
        let config = await registry.config(for: .openRouter)
        #expect(enabled == true)
        #expect(config?.apiKey == "fallback-key")
    }

    @Test
    func `canonical openrouter key wins over every alias`() async {
        let r = ConfigReader(providers: [InMemoryProvider(values: [
            "llm.provider.openRouter.apiKey": cfg("canonical"),
            "llm.provider.openrouter.apikey": cfg("legacy"),
            "openrouter.api_key": cfg("alias"),
            "openrouter.fallback_api_key": cfg("fallback-key"),
        ])])
        let registry = ProviderRegistry.from(reader: r, adapters: [], logger: Logger(label: "test"))
        let config = await registry.config(for: .openRouter)
        #expect(config?.apiKey == "canonical")
    }

    @Test
    func `missing api key disables provider`() async {
        let r = ConfigReader(providers: [InMemoryProvider(values: [
            "llm.provider.anthropic.apiKey": cfg("a-key"),
        ])])
        let registry = ProviderRegistry.from(reader: r, adapters: [], logger: Logger(label: "test"))
        let isAnthropic = await registry.isEnabled(.anthropic)
        let isOpenAI = await registry.isEnabled(.openai)
        #expect(isAnthropic == true)
        #expect(isOpenAI == false)
    }

    @Test
    func `whitespace only api key counts as missing`() async {
        let r = ConfigReader(providers: [InMemoryProvider(values: [
            "llm.provider.anthropic.apiKey": cfg("   "),
        ])])
        let registry = ProviderRegistry.from(reader: r, adapters: [], logger: Logger(label: "test"))
        let isAnthropic = await registry.isEnabled(.anthropic)
        #expect(isAnthropic == false)
    }

    @Test
    func `optional base url is honored`() async {
        let r = ConfigReader(providers: [InMemoryProvider(values: [
            "llm.provider.together.apiKey": cfg("t-key"),
            "llm.provider.together.baseURL": cfg("https://example.together"),
        ])])
        let registry = ProviderRegistry.from(reader: r, adapters: [], logger: Logger(label: "test"))
        let cfg = await registry.config(for: .together)
        #expect(cfg?.baseURL?.absoluteString == "https://example.together")
    }

    @Test
    func `hermes gateway enabled iff adapter registered`() async {
        let r = ConfigReader(providers: [InMemoryProvider(values: [:])])
        let emptyRegistry = ProviderRegistry.from(reader: r, adapters: [], logger: Logger(label: "test"))
        let emptyIsEnabled = await emptyRegistry.isEnabled(.hermesGateway)
        #expect(emptyIsEnabled == false)

        struct StubAdapter: ProviderAdapter {
            let kind: ProviderKind = .hermesGateway
            func chatCompletions(payload _: Data, sessionKey _: String, sessionID _: String?) async throws -> Data {
                Data()
            }
        }
        let withAdapter = ProviderRegistry.from(reader: r, adapters: [StubAdapter()], logger: Logger(label: "test"))
        let withAdapterIsEnabled = await withAdapter.isEnabled(.hermesGateway)
        #expect(withAdapterIsEnabled == true)
    }
}
