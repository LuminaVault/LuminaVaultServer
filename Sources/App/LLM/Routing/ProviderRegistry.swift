import Configuration
import Foundation
import Logging
import ServiceLifecycle

/// HER-161 — env-loaded provider credential snapshot. Empty `apiKey`
/// disables the provider (so deployments only configure what they own).
struct ProviderConfig: Hashable {
    let kind: ProviderKind
    let apiKey: String
    let baseURL: URL?

    var isEnabled: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// HER-165 — runtime adapter map. Constructed once at boot in
/// `App+build` and populated with every adapter the deployment has
/// credentials for. `RoutedLLMTransport` queries it to resolve a
/// `ProviderKind` decision from `ModelRouter` into a callable adapter.
///
/// Actor so registration + lookup never race. Read-heavy workload — the
/// registry is written exactly once at boot and read on every chat call.
///
/// HER-161 — conforms to `Service` so `ServiceGroup` keeps the registry
/// alive for the application's lifetime; `run()` blocks until cancellation.
actor ProviderRegistry: Service {
    private var adapters: [ProviderKind: any ProviderAdapter] = [:]
    private var configs: [ProviderKind: ProviderConfig] = [:]
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    /// Boot-time convenience: seed the registry with adapters known at
    /// construction. `buildRouter` is currently synchronous, so we can't
    /// `await register(...)` from boot — the seed list is wired through
    /// this init instead. Late registration still goes through `register`.
    init(
        configs: [ProviderConfig] = [],
        adapters: [any ProviderAdapter],
        logger: Logger
    ) {
        self.logger = logger
        for config in configs where config.isEnabled {
            self.configs[config.kind] = config
            logger.info("provider config enabled: \(config.kind.rawValue)")
        }
        for adapter in adapters {
            self.adapters[adapter.kind] = adapter
            logger.info("provider registered: \(adapter.kind.rawValue)")
        }
    }

    /// HER-161 — env-loaded factory. Reads `llm.provider.<key>.apiKey` and
    /// `llm.provider.<key>.baseURL` for each of the 7 spec providers; a
    /// missing or empty key disables that provider rather than crashing.
    static func from(reader: ConfigReader, adapters: [any ProviderAdapter], logger: Logger) -> ProviderRegistry {
        let configs = loadConfigs(from: reader)
        // Self-reporting guard for the env-name class of bug: a provider whose
        // key failed to load is silently absent rather than failing the boot, so
        // this line is the only cheap way to notice. `openRouter` and `nvidia`
        // must both appear for the free lane to have any capacity.
        logger.info("llm providers enabled", metadata: [
            "providers": .string(configs.map(\.kind.rawValue).sorted().joined(separator: ",")),
        ])
        return ProviderRegistry(
            configs: configs,
            adapters: adapters,
            logger: logger
        )
    }

    /// Idempotent. Re-registering the same kind overwrites the previous
    /// entry — useful for tests that swap a stub in mid-suite.
    func register(_ adapter: any ProviderAdapter) {
        adapters[adapter.kind] = adapter
        logger.info("provider registered: \(adapter.kind.rawValue)")
    }

    func adapter(for kind: ProviderKind) -> (any ProviderAdapter)? {
        adapters[kind]
    }

    func config(for kind: ProviderKind) -> ProviderConfig? {
        configs[kind]
    }

    /// `hermesGateway` is always-on when an adapter is registered (no API
    /// key required since it's in-cluster). Every other provider must have
    /// an `apiKey` configured to be eligible for routing.
    func isEnabled(_ kind: ProviderKind) -> Bool {
        if kind == .hermesGateway {
            return adapters[kind] != nil
        }
        return configs[kind]?.isEnabled == true
    }

    /// Snapshot of the registered kinds — useful for observability /
    /// startup logging. Order is implementation-defined; don't rely on it.
    func registered() -> [ProviderKind] {
        Array(adapters.keys)
    }

    func enabledProviders() -> [ProviderKind] {
        Array(configs.keys)
    }

    func run() async throws {
        try await gracefulShutdown()
    }

    private static func loadConfigs(from reader: ConfigReader) -> [ProviderConfig] {
        [
            loadConfig(kind: .anthropic, key: "anthropic", reader: reader),
            loadConfig(kind: .openai, key: "openai", reader: reader),
            loadConfig(
                kind: .openRouter,
                key: "openRouter",
                fallbackAPIKey: reader.string(forKey: ConfigKey("openrouter.api_key"), isSecret: true, default: ""),
                reader: reader
            ),
            // Free lane leg 2 — NVIDIA NIM direct. `isEnabled(.nvidia)` is what
            // gates that leg, so the platform key must be visible here even though
            // the adapter itself is registered unconditionally for BYOK tenants.
            loadConfig(
                kind: .nvidia,
                key: "nvidia",
                fallbackAPIKey: reader.string(forKey: ConfigKey("nvidia.api_key"), isSecret: true, default: ""),
                reader: reader
            ),
            loadConfig(kind: .gemini, key: "gemini", reader: reader),
            loadConfig(kind: .together, key: "together", reader: reader),
            loadConfig(kind: .groq, key: "groq", reader: reader),
            loadConfig(kind: .fireworks, key: "fireworks", reader: reader),
            // HER-164 — DeepInfra slot added; OpenAI-compatible adapter
            // handles together/groq/fireworks/deepInfra/deepseekDirect.
            loadConfig(kind: .deepInfra, key: "deepInfra", reader: reader),
            loadConfig(kind: .deepseekDirect, key: "deepseekDirect", reader: reader),
        ].compactMap(\.self)
    }

    /// Canonical config key for a provider's API key.
    ///
    /// `ConfigReader` resolves a dotted key against the environment by encoding it:
    /// components are split on `.`, camelCase boundaries become `_`, everything is
    /// uppercased (`swift-configuration`'s `EnvironmentKeyEncoder`). So
    /// `llm.provider.openRouter.apiKey` reads **`LLM_PROVIDER_OPEN_ROUTER_API_KEY`** —
    /// not the `LLM_PROVIDER_OPENROUTER_APIKEY` that every .env and compose file
    /// shipped, which is why the platform OpenRouter key silently never loaded.
    static func apiKeyConfigKey(_ key: String) -> String {
        "llm.provider.\(key).apiKey"
    }

    /// The pre-fix spelling, kept working so deployments heal without an ops step.
    /// An all-lowercase key has no camelCase boundaries, so it encodes verbatim:
    /// `llm.provider.openrouter.apikey` → `LLM_PROVIDER_OPENROUTER_APIKEY`.
    static func legacyAPIKeyConfigKey(_ key: String) -> String {
        "llm.provider.\(key.lowercased()).apikey"
    }

    private static func loadConfig(kind: ProviderKind, key: String, fallbackAPIKey: String = "", reader: ConfigReader) -> ProviderConfig? {
        let configured = reader.string(forKey: ConfigKey(Self.apiKeyConfigKey(key)), isSecret: true, default: "")
        let legacy = reader.string(forKey: ConfigKey(Self.legacyAPIKeyConfigKey(key)), isSecret: true, default: "")
        let apiKey = [configured, legacy, fallbackAPIKey].first { !$0.isEmpty } ?? ""
        let rawBaseURL = [
            reader.string(forKey: ConfigKey("llm.provider.\(key).baseURL"), default: ""),
            reader.string(forKey: ConfigKey("llm.provider.\(key.lowercased()).baseurl"), default: ""),
        ]
        .lazy
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        let baseURL = rawBaseURL.isEmpty ? nil : URL(string: rawBaseURL)
        let config = ProviderConfig(kind: kind, apiKey: apiKey, baseURL: baseURL)
        return config.isEnabled ? config : nil
    }
}
