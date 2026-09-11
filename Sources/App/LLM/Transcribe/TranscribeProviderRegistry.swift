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

    init(
        active: TranscribeProviderKind,
        configs: [TranscribeProviderConfig] = [],
        adapters: [any TranscribeProviderAdapter],
        logger: Logger
    ) {
        activeKind = active
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
        return TranscribeProviderRegistry(
            active: active,
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
        let rawBaseURL = reader.string(forKey: ConfigKey("transcribe.provider.\(key).baseURL"), default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = rawBaseURL.isEmpty ? nil : URL(string: rawBaseURL)
        let model = reader.string(forKey: ConfigKey("transcribe.provider.\(key).model"), default: defaultModel(for: kind))
        let mtokPerSecond = reader.double(forKey: ConfigKey("transcribe.ratecard.\(key).mtokPerSecond"), default: defaultRateCard(for: kind))
        let config = TranscribeProviderConfig(
            kind: kind,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            mtokPerSecond: mtokPerSecond
        )
        return config.isEnabled ? config : nil
    }

    private static func defaultModel(for kind: TranscribeProviderKind) -> String {
        switch kind {
        // The model the in-cluster service preloads. A hosted endpoint needs
        // its own name set explicitly; there is no safe cross-vendor default.
        case .openaiCompatible: "Systran/faster-whisper-small.en"
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
}
