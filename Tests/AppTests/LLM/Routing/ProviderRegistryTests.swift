@testable import App
import Configuration
import Foundation
import Logging
import Testing

/// HER-161 — `ProviderRegistry` env-loading + enablement gating.
@Suite(.serialized)
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
            func chatCompletions(payload _: Data, profileUsername _: String) async throws -> Data {
                Data()
            }
        }
        let withAdapter = ProviderRegistry.from(reader: r, adapters: [StubAdapter()], logger: Logger(label: "test"))
        let withAdapterIsEnabled = await withAdapter.isEnabled(.hermesGateway)
        #expect(withAdapterIsEnabled == true)
    }
}
