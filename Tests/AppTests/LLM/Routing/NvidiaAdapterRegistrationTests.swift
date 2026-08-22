@testable import App
import Foundation
import Logging
import Testing

/// `.nvidia` existed as a `ProviderKind` with a base URL, catalog entries, and a
/// slot in the iOS providers pane — but no adapter was ever registered, so every
/// NVIDIA route died in `RoutedLLMTransport` as "unregistered provider". These
/// guard the wiring that fixes that, and that the free lane's NIM leg can
/// actually be dispatched.
struct NvidiaAdapterRegistrationTests {
    private static func registry(nvidiaKey: String) -> ProviderRegistry {
        let logger = Logger(label: "test.nvidia")
        return ProviderRegistry(
            configs: nvidiaKey.isEmpty ? [] : [
                ProviderConfig(kind: .nvidia, apiKey: nvidiaKey, baseURL: nil),
            ],
            adapters: [
                OpenAICompatibleAdapter(
                    kind: .nvidia,
                    apiKey: nvidiaKey,
                    baseURL: OpenAICompatibleAdapter.defaultBaseURL(for: .nvidia),
                    logger: logger
                ),
            ],
            logger: logger
        )
    }

    @Test("an nvidia adapter is resolvable")
    func adapterRegistered() async {
        let adapter = await Self.registry(nvidiaKey: "nvapi-test").adapter(for: .nvidia)
        #expect(adapter != nil)
    }

    /// The adapter is registered unconditionally so BYOK-NVIDIA tenants work
    /// with no platform key, but `isEnabled` is what gates the *free lane's*
    /// NIM leg — that leg spends platform money, so it needs a platform key.
    @Test("isEnabled tracks the platform key, not adapter registration")
    func isEnabledTracksPlatformKey() async {
        #expect(await Self.registry(nvidiaKey: "").isEnabled(.nvidia) == false)
        #expect(await Self.registry(nvidiaKey: "nvapi-test").isEnabled(.nvidia) == true)
    }

    @Test("nvidia resolves to the NIM OpenAI-compatible endpoint")
    func endpointIsNIM() {
        let base = OpenAICompatibleAdapter.defaultBaseURL(for: .nvidia)
        #expect(base.absoluteString == "https://integrate.api.nvidia.com")
        let endpoint = OpenAICompatibleAdapter.endpoint(for: .nvidia, baseURL: base)
        #expect(endpoint.absoluteString == "https://integrate.api.nvidia.com/v1/chat/completions")
    }

    /// Legacy env spellings must keep resolving so an existing .env.production
    /// heals on deploy instead of needing a manual rename.
    @Test("legacy api-key config keys encode to the shipped env var names")
    func legacyConfigKeySpellings() {
        #expect(ProviderRegistry.apiKeyConfigKey("openRouter") == "llm.provider.openRouter.apiKey")
        #expect(ProviderRegistry.legacyAPIKeyConfigKey("openRouter") == "llm.provider.openrouter.apikey")
        #expect(ProviderRegistry.legacyAPIKeyConfigKey("deepInfra") == "llm.provider.deepinfra.apikey")
        #expect(ProviderRegistry.legacyAPIKeyConfigKey("nvidia") == "llm.provider.nvidia.apikey")
    }
}
