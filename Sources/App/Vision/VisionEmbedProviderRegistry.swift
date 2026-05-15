import Configuration
import Foundation
import Logging
import ServiceLifecycle

/// HER-205 — env-loaded provider credential snapshot for the vision-embed
/// layer. Mirrors `ProviderConfig` / `TranscribeProviderConfig`. Empty
/// `apiKey` disables the provider.
struct VisionEmbedProviderConfig: Hashable {
    let kind: VisionEmbedProviderKind
    let apiKey: String
    let baseURL: URL?
    let model: String

    var isEnabled: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// HER-205 — runtime adapter map for image embeddings. One active adapter
/// per boot, selected by `vision.embed.provider` env knob. Modelled on
/// `TranscribeProviderRegistry` so failover policy (when we add it) can
/// stay independent of chat / STT.
actor VisionEmbedProviderRegistry: Service {
    private var adapters: [VisionEmbedProviderKind: any VisionEmbedProviderAdapter] = [:]
    private var configs: [VisionEmbedProviderKind: VisionEmbedProviderConfig] = [:]
    private let activeKind: VisionEmbedProviderKind
    private let logger: Logger

    init(
        active: VisionEmbedProviderKind,
        configs: [VisionEmbedProviderConfig] = [],
        adapters: [any VisionEmbedProviderAdapter],
        logger: Logger,
    ) {
        self.activeKind = active
        self.logger = logger
        for config in configs where config.isEnabled {
            self.configs[config.kind] = config
            logger.info("vision embed provider config enabled: \(config.kind.rawValue)")
        }
        for adapter in adapters {
            self.adapters[adapter.kind] = adapter
            logger.info("vision embed provider registered: \(adapter.kind.rawValue)")
        }
    }

    static func from(
        reader: ConfigReader,
        adapters: [any VisionEmbedProviderAdapter],
        logger: Logger,
    ) -> VisionEmbedProviderRegistry {
        let activeRaw = reader.string(forKey: ConfigKey("vision.embed.provider"), default: "cohere")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let active = VisionEmbedProviderKind(rawValue: activeRaw) ?? .cohere
        return VisionEmbedProviderRegistry(
            active: active,
            configs: loadConfigs(from: reader),
            adapters: adapters,
            logger: logger,
        )
    }

    func active() -> (any VisionEmbedProviderAdapter)? {
        adapters[activeKind]
    }

    func activeKindResolved() -> VisionEmbedProviderKind {
        activeKind
    }

    func config(for kind: VisionEmbedProviderKind) -> VisionEmbedProviderConfig? {
        configs[kind]
    }

    func register(_ adapter: any VisionEmbedProviderAdapter) {
        adapters[adapter.kind] = adapter
        logger.info("vision embed provider registered: \(adapter.kind.rawValue)")
    }

    func run() async throws {
        try await gracefulShutdown()
    }

    private static func loadConfigs(from reader: ConfigReader) -> [VisionEmbedProviderConfig] {
        VisionEmbedProviderKind.allCases.compactMap { kind in
            loadConfig(kind: kind, reader: reader)
        }
    }

    private static func loadConfig(
        kind: VisionEmbedProviderKind,
        reader: ConfigReader,
    ) -> VisionEmbedProviderConfig? {
        let key = kind.rawValue
        let apiKey = reader.string(forKey: ConfigKey("vision.embed.provider.\(key).apiKey"), isSecret: true, default: "")
        let rawBaseURL = reader.string(forKey: ConfigKey("vision.embed.provider.\(key).baseURL"), default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = rawBaseURL.isEmpty ? nil : URL(string: rawBaseURL)
        let model = reader.string(forKey: ConfigKey("vision.embed.provider.\(key).model"), default: defaultModel(for: kind))
        let config = VisionEmbedProviderConfig(
            kind: kind,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
        )
        return config.isEnabled ? config : nil
    }

    private static func defaultModel(for kind: VisionEmbedProviderKind) -> String {
        switch kind {
        case .cohere: "embed-image-v3.0"
        case .openai: "text-embedding-3-small" // placeholder — OpenAI has no public image-embedding model yet
        case .replicate: "openai/clip-vit-large-patch14"
        case .hermesVision: "hermes-vision-1"
        case .stub: "stub"
        }
    }
}
