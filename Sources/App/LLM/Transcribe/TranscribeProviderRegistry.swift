import Configuration
import Foundation
import Logging
import ServiceLifecycle

/// HER-203 — env-loaded provider credential snapshot for the STT layer.
/// Mirrors `ProviderConfig` from the chat-routing layer but scoped to
/// transcription. A provider with neither a key nor a base URL is disabled,
/// so deployments only configure what they own.
struct TranscribeProviderConfig: Hashable {
    let kind: TranscribeProviderKind
    let apiKey: String
    let baseURL: URL?
    let model: String
    /// Mtok-equivalent units credited to the usage meter per second of
    /// transcribed audio. Per-provider so we can swap providers without
    /// re-pricing the whole rate card.
    let mtokPerSecond: Double
    /// USD per minute of audio at this provider's *published* rate, used to
    /// impute what the traffic would have cost hosted.
    ///
    /// Deliberately separate from real spend, which stays zero for the
    /// in-cluster service: this is not money anyone owes, it is the number
    /// that turns "running our own whisper is cheaper" into a measurement.
    /// Never reaches `cost_ledger`.
    let imputedUsdPerAudioMinute: Double

    /// A provider is usable once it has *either* a credential or an endpoint.
    ///
    /// The in-cluster whisper service takes no API key — access is controlled
    /// by NetworkPolicy — so requiring one would leave it permanently
    /// disabled. A configured base URL is the deliberate act that enables it.
    var isEnabled: Bool {
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return baseURL != nil
    }
}

/// HER-203 — runtime adapter map for STT. One active adapter per boot,
/// selected by `transcribe.provider` env knob. Modelled on
/// `ProviderRegistry` (`Sources/App/LLM/Routing/ProviderRegistry.swift`)
/// but scoped to transcription so chat-routing failover policy stays
/// independent.
///
/// Actor so registration + lookup never race. Conforms to `Service` so
/// `ServiceGroup` keeps the registry alive for the app's lifetime.
actor TranscribeProviderRegistry: Service {
    private var adapters: [TranscribeProviderKind: any TranscribeProviderAdapter] = [:]
    private var configs: [TranscribeProviderKind: TranscribeProviderConfig] = [:]
    private let activeKind: TranscribeProviderKind
    private let logger: Logger

    /// True when `transcribe.provider` named something unknown and the
    /// registry substituted a default. Exposed so the condition is assertable
    /// rather than only visible in a log line nobody reads.
    let activeKindWasFallback: Bool

    /// The cluster's own whisper. Free per request, no credential (access is
    /// controlled by NetworkPolicy), and no audio leaves the cluster — see
    /// `~/Work/production/CLAUDE.md`, which forbids adding a paid speech API.
    ///
    /// The version prefix is part of the URL, matching how every
    /// OpenAI-compatible endpoint publishes itself.
    static let inClusterWhisperBaseURL = URL(string: "http://whisper.horus.svc.cluster.local:8000/v1")!

    init(
        active: TranscribeProviderKind,
        activeKindWasFallback: Bool = false,
        configs: [TranscribeProviderConfig] = [],
        adapters: [any TranscribeProviderAdapter],
        logger: Logger
    ) {
        activeKind = active
        self.activeKindWasFallback = activeKindWasFallback
        self.logger = logger
        for config in configs where config.isEnabled {
            self.configs[config.kind] = config
            logger.info("transcribe provider config enabled: \(config.kind.rawValue)")
        }
        for adapter in adapters {
            self.adapters[adapter.kind] = adapter
            logger.info("transcribe provider registered: \(adapter.kind.rawValue)")
        }
    }

    /// Env-loaded factory. Reads `transcribe.provider`, then per-provider
    /// keys under `transcribe.provider.<kind>.{apiKey,baseURL,model}` and
    /// `transcribe.ratecard.<kind>.mtokPerSecond`. Missing keys disable
    /// that provider rather than crashing boot.
    static func from(
        reader: ConfigReader,
        adapters: [any TranscribeProviderAdapter],
        logger: Logger
    ) -> TranscribeProviderRegistry {
        let activeRaw = reader.string(forKey: ConfigKey("transcribe.provider"), default: "openai_compatible")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let active = TranscribeProviderKind(rawValue: activeRaw) ?? .openaiCompatible
        // Falling back beats failing boot on a voice path, but a silent
        // fallback is how a deployment ends up convinced it selected one
        // provider while serving from another. `groq` was the default for
        // months and is no longer a kind, so this is not hypothetical.
        let wasFallback = TranscribeProviderKind(rawValue: activeRaw) == nil
        if wasFallback {
            logger.warning("""
            transcribe.provider=\(activeRaw) is not a known provider — \
            falling back to \(active.rawValue). Known: \
            \(TranscribeProviderKind.allCases.map(\.rawValue).joined(separator: ", "))
            """)
        }
        return TranscribeProviderRegistry(
            active: active,
            activeKindWasFallback: wasFallback,
            configs: loadConfigs(from: reader),
            adapters: adapters,
            logger: logger
        )
    }

    func active() -> (any TranscribeProviderAdapter)? {
        adapters[activeKind]
    }

    func activeKindResolved() -> TranscribeProviderKind {
        activeKind
    }

    func config(for kind: TranscribeProviderKind) -> TranscribeProviderConfig? {
        configs[kind]
    }

    func mtokPerSecond(for kind: TranscribeProviderKind) -> Double {
        configs[kind]?.mtokPerSecond ?? 0
    }

    /// The model name this provider is configured to send. Recorded on each
    /// usage event so a rate change is attributable to the model that caused
    /// it, rather than showing up as an unexplained step in the cost chart.
    func model(for kind: TranscribeProviderKind) -> String? {
        configs[kind]?.model
    }

    /// Shadow pricing for the usage events. A provider with no config yields
    /// a zero card, which imputes nothing — the safe default, since inventing
    /// a rate nobody set would be worse than having no number.
    func rateCard(for kind: TranscribeProviderKind) -> TranscribeRateCard {
        TranscribeRateCard(
            imputedUsdPerAudioMinute: configs[kind]?.imputedUsdPerAudioMinute ?? 0
        )
    }

    /// Idempotent. Re-registering the same kind overwrites the previous
    /// entry — used by tests to swap a stub in mid-suite.
    func register(_ adapter: any TranscribeProviderAdapter) {
        adapters[adapter.kind] = adapter
        logger.info("transcribe provider registered: \(adapter.kind.rawValue)")
    }

    func run() async throws {
        try await gracefulShutdown()
    }

    private static func loadConfigs(from reader: ConfigReader) -> [TranscribeProviderConfig] {
        TranscribeProviderKind.allCases.compactMap { kind in
            loadConfig(kind: kind, reader: reader)
        }
    }

    private static func loadConfig(
        kind: TranscribeProviderKind,
        reader: ConfigReader
    ) -> TranscribeProviderConfig? {
        let key = kind.configKey
        let apiKey = reader.string(forKey: ConfigKey("transcribe.provider.\(key).apiKey"), isSecret: true, default: "")
        // Defaulted, not left empty. The in-cluster whisper takes no
        // credential, so a deployment that uses it sets no TRANSCRIBE_*
        // variable at all — and with both fields blank `isEnabled` was false,
        // so no config row was stored. Everything hanging off the config then
        // silently degraded: usage rows recorded an empty model name, and the
        // imputed rate card read `0` no matter what the operator set.
        let rawBaseURL = reader.string(forKey: ConfigKey("transcribe.provider.\(key).baseURL"), default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = rawBaseURL.isEmpty ? defaultBaseURL(for: kind) : URL(string: rawBaseURL)
        let model = reader.string(forKey: ConfigKey("transcribe.provider.\(key).model"), default: defaultModel(for: kind))
        let mtokPerSecond = reader.double(forKey: ConfigKey("transcribe.ratecard.\(key).mtokPerSecond"), default: defaultRateCard(for: kind))
        let imputedUsdPerAudioMinute = reader.double(
            forKey: ConfigKey("transcribe.ratecard.\(key).imputedUsdPerAudioMinute"),
            default: defaultImputedRate(for: kind)
        )
        let config = TranscribeProviderConfig(
            kind: kind,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            mtokPerSecond: mtokPerSecond,
            imputedUsdPerAudioMinute: imputedUsdPerAudioMinute
        )
        return config.isEnabled ? config : nil
    }

    /// Endpoint used when none is configured.
    ///
    /// Only the OpenAI-compatible kind has one, and it is the cluster's own
    /// whisper — the same URL `App+build` hands the adapter, read from here
    /// so the two cannot drift into disagreeing about where audio goes. The
    /// stub has no endpoint by design: it must never look configured unless a
    /// test asks for it.
    static func defaultBaseURL(for kind: TranscribeProviderKind) -> URL? {
        switch kind {
        case .openaiCompatible: inClusterWhisperBaseURL
        case .stub: nil
        }
    }

    private static func defaultModel(for kind: TranscribeProviderKind) -> String {
        switch kind {
        // The multilingual model the in-cluster service preloads. A hosted
        // endpoint needs its own name set explicitly; there is no safe
        // cross-vendor default.
        case .openaiCompatible: "Systran/faster-whisper-small"
        case .stub: "stub"
        }
    }

    /// Mtok-equivalent per second of audio, for the usage meter.
    ///
    /// Zero by default: the in-cluster service costs nothing per request, so
    /// metering it as though it did would invent spend. A deployment pointing
    /// at a paid endpoint sets `transcribe.ratecard.<kind>.mtokPerSecond`
    /// explicitly.
    private static func defaultRateCard(for kind: TranscribeProviderKind) -> Double {
        switch kind {
        case .openaiCompatible, .stub: 0.0
        }
    }

    /// USD per audio-minute used only to impute what this traffic would have
    /// cost on a hosted provider.
    ///
    /// Zero by default, for the same reason the meter rate is: a number
    /// nobody configured is a number nobody should act on. Set
    /// `transcribe.ratecard.<kind>.imputedUsdPerAudioMinute` to the hosted
    /// provider's published rate (OpenAI's whisper-1 is 0.006) and the usage
    /// events start carrying the savings figure.
    private static func defaultImputedRate(for kind: TranscribeProviderKind) -> Double {
        switch kind {
        case .openaiCompatible, .stub: 0.0
        }
    }
}
