import Configuration
import Foundation
import Logging
import ServiceLifecycle

/// HER-203 — env-loaded provider credential snapshot for the STT layer.
/// Mirrors `ProviderConfig` from the chat-routing layer but scoped to
/// transcription. Empty `apiKey` disables the provider (so deployments
/// only configure what they own).
struct TranscribeProviderConfig: Hashable {
    let kind: TranscribeProviderKind
    let apiKey: String
    let baseURL: URL?
    let model: String
    /// Mtok-equivalent units credited to the usage meter per second of
    /// transcribed audio. Per-provider so we can swap providers without
    /// re-pricing the whole rate card.
    let mtokPerSecond: Double

    var isEnabled: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        logger: Logger,
    ) {
        self.activeKind = active
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
        logger: Logger,
    ) -> TranscribeProviderRegistry {
        let activeRaw = reader.string(forKey: ConfigKey("transcribe.provider"), default: "groq")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let active = TranscribeProviderKind(rawValue: activeRaw) ?? .groq
        return TranscribeProviderRegistry(
            active: active,
            configs: loadConfigs(from: reader),
            adapters: adapters,
            logger: logger,
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
        reader: ConfigReader,
    ) -> TranscribeProviderConfig? {
        let key = kind.rawValue
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
            mtokPerSecond: mtokPerSecond,
        )
        return config.isEnabled ? config : nil
    }

    private static func defaultModel(for kind: TranscribeProviderKind) -> String {
        switch kind {
        case .groq: "whisper-large-v3"
        case .openai: "whisper-1"
        case .replicate: "openai/whisper"
        case .stub: "stub"
        }
    }

    private static func defaultRateCard(for kind: TranscribeProviderKind) -> Double {
        switch kind {
        case .groq, .openai, .replicate: 0.0001
        case .stub: 0.0
        }
    }
}
