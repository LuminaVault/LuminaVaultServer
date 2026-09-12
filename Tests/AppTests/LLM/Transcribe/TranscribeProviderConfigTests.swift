@testable import App
import Configuration
import Foundation
import Logging
import Testing

/// Config loading for the transcription provider.
///
/// The invariant that matters: the cluster's own whisper is the default
/// provider and takes **no credential** — access is controlled by
/// NetworkPolicy. So the default deployment sets no `TRANSCRIBE_*` variable
/// at all, and everything downstream of the config — the model name on each
/// usage row, the imputed rate card — has to work in exactly that case.
struct TranscribeProviderConfigTests {
    static func registry(env: [AbsoluteConfigKey: ConfigValue] = [:]) -> TranscribeProviderRegistry {
        TranscribeProviderRegistry.from(
            reader: ConfigReader(providers: [InMemoryProvider(values: env)]),
            adapters: [],
            logger: Logger(label: "test")
        )
    }

    /// The bug this pins: with no env set, `isEnabled` was false (no key, no
    /// base URL), so no config row was stored — and every lookup that hangs
    /// off the config silently returned a default. Voice rows recorded an
    /// empty model, and the imputed rate card was `0` no matter what the
    /// operator configured.
    @Test
    func `the cluster whisper is configured with no environment at all`() async {
        let registry = Self.registry()
        let config = await registry.config(for: .openaiCompatible)
        #expect(config != nil, "the in-cluster provider must be configured by default")
        #expect(config?.baseURL == TranscribeProviderRegistry.inClusterWhisperBaseURL)
        #expect(config?.apiKey == "", "the in-cluster service authenticates by NetworkPolicy")
    }

    @Test
    func `the default model reaches the usage row`() async {
        let registry = Self.registry()
        let model = await registry.model(for: .openaiCompatible)
        #expect(model == "Systran/faster-whisper-small")
    }

    /// The whole point of the shadow rate: an operator sets it, and it shows
    /// up on the rows. It has to survive a deployment that configures nothing
    /// else, which is the deployment we actually run.
    @Test
    func `the imputed rate applies with no other transcribe config set`() async {
        let registry = Self.registry(env: [
            "transcribe.ratecard.openai.imputedUsdPerAudioMinute": cfg(0.006),
        ])
        let card = await registry.rateCard(for: .openaiCompatible)
        #expect(card.imputedUsdMicros(durationSeconds: 60) == 6000)
    }

    @Test
    func `an explicit base URL still overrides the in-cluster default`() async {
        let registry = Self.registry(env: [
            "transcribe.provider.openai.baseURL": cfg("https://api.example.com/v1"),
        ])
        let config = await registry.config(for: .openaiCompatible)
        #expect(config?.baseURL?.absoluteString == "https://api.example.com/v1")
    }

    // MARK: - Environment variable spellings

    /// The names an operator actually types.
    ///
    /// `ConfigReader` encodes a dotted key by splitting on `.`, inserting `_`
    /// where a lowercase letter is followed by an uppercase one, and
    /// uppercasing. So `baseURL` becomes `BASE_URL` and `apiKey` becomes
    /// `API_KEY` — **not** the flattened `BASEURL`/`APIKEY` spellings that
    /// shipped in .env files for months and silently loaded nothing.
    /// `ProviderRegistry` carries legacy aliases for that mistake; the
    /// transcribe path never did, so the canonical spelling is the only one
    /// that works and this pins it.
    static func envRegistry(_ env: [String: String]) -> TranscribeProviderRegistry {
        TranscribeProviderRegistry.from(
            reader: ConfigReader(providers: [EnvironmentVariablesProvider(environmentVariables: env)]),
            adapters: [],
            logger: Logger(label: "test")
        )
    }

    @Test
    func `the canonical env spellings load`() async {
        let registry = Self.envRegistry([
            "TRANSCRIBE_PROVIDER_OPENAI_BASE_URL": "https://api.example.com/v1",
            "TRANSCRIBE_PROVIDER_OPENAI_API_KEY": "sk-test",
            "TRANSCRIBE_PROVIDER_OPENAI_MODEL": "whisper-1",
            "TRANSCRIBE_RATECARD_OPENAI_IMPUTED_USD_PER_AUDIO_MINUTE": "0.006",
        ])
        let config = await registry.config(for: .openaiCompatible)
        #expect(config?.baseURL?.absoluteString == "https://api.example.com/v1")
        #expect(config?.apiKey == "sk-test")
        #expect(config?.model == "whisper-1")
        #expect(config?.imputedUsdPerAudioMinute == 0.006)
    }

    /// The failure this documents is silent: the variable is set, nothing
    /// reads it, and the deployment keeps using the in-cluster default while
    /// its .env says otherwise.
    @Test
    func `the flattened env spellings load nothing`() async {
        let registry = Self.envRegistry([
            "TRANSCRIBE_PROVIDER_OPENAI_BASEURL": "https://api.example.com/v1",
            "TRANSCRIBE_PROVIDER_OPENAI_APIKEY": "sk-test",
        ])
        let config = await registry.config(for: .openaiCompatible)
        #expect(config?.baseURL == TranscribeProviderRegistry.inClusterWhisperBaseURL)
        #expect(config?.apiKey == "")
    }

    // MARK: - Provider selection

    @Test
    func `an unset provider selects the in-cluster whisper`() async {
        let registry = Self.registry()
        #expect(await registry.activeKindResolved() == .openaiCompatible)
    }

    /// `groq` was the old default and is no longer a kind. It — and any typo —
    /// falls back rather than failing boot, which is the right call for a
    /// voice path, but the fallback must be visible: a deployment that thinks
    /// it selected a provider and silently got another one is how you debug
    /// the wrong system for an afternoon.
    @Test
    func `an unrecognised provider name falls back and is reported`() async {
        let registry = Self.registry(env: ["transcribe.provider": cfg("groq")])
        #expect(await registry.activeKindResolved() == .openaiCompatible)
        #expect(await registry.activeKindWasFallback == true)
    }

    @Test
    func `a recognised provider name is not reported as a fallback`() async {
        let registry = Self.registry(env: ["transcribe.provider": cfg("openai_compatible")])
        #expect(await registry.activeKindWasFallback == false)
    }
}
