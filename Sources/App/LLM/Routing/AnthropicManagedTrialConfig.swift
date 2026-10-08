import Configuration
import Foundation

/// Settings for the Claude Haiku trial: Anthropic as the first rung of
/// platform-paid (managed) routing, with the existing chain kept behind it as
/// the fallback.
///
/// Read from the env contract shared by every app in the trial:
///
/// | Env                  | Config key           | Meaning                                   |
/// |----------------------|----------------------|-------------------------------------------|
/// | `ANTHROPIC_API_KEY`  | `anthropic.apiKey`   | Unset → no trial, behaviour as before.    |
/// | `ANTHROPIC_FIRST`    | `anthropic.first`    | `true` turns the trial on. Rollback flag. |
/// | `ANTHROPIC_MODEL`    | `anthropic.model`    | Default `claude-haiku-5-5`.               |
/// | `ANTHROPIC_EFFORT`   | `anthropic.effort`   | `low` … `max`; unset = model default.     |
/// | `ANTHROPIC_THINKING` | `anthropic.thinking` | `adaptive` (default) or `disabled`.       |
/// | `ANTHROPIC_SCOPE`    | `anthropic.scope`    | `all` (default) or `paid` (skip free lane)|
///
/// `swift-configuration` encodes `anthropic.apiKey` as `ANTHROPIC_API_KEY`
/// (camelCase boundary → `_`, see `ProviderRegistry.apiKeyConfigKey`).
///
/// The trial key is deliberately **not** read by `ProviderRegistry`. Enabling
/// `.anthropic` there would put Sonnet and Opus at the front of pro table
/// routing and Opus into the Auto pools. The key only reaches
/// `AnthropicAdapter`, and `AnthropicManagedTrialRouter` is the only thing that
/// routes to it.
struct AnthropicManagedTrialConfig: Hashable {
    enum Thinking: String, Hashable {
        case adaptive
        case disabled
    }

    enum Scope: String, Hashable {
        /// Free-lane decisions get Anthropic first too.
        case all
        /// Only decisions that are not on the free lane.
        case paid
    }

    static let defaultModel = "claude-haiku-5-5"
    static let efforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    let apiKey: String
    let model: String
    let effort: String?
    let thinking: Thinking
    let scope: Scope

    init(
        apiKey: String,
        model: String = Self.defaultModel,
        effort: String? = nil,
        thinking: Thinking = .adaptive,
        scope: Scope = .all
    ) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.thinking = thinking
        self.scope = scope
    }

    /// The route the trial puts in front of every eligible decision.
    var route: ModelRoute {
        ModelRoute(provider: .anthropic, modelID: model)
    }

    /// `nil` unless `ANTHROPIC_FIRST=true` and a key resolves — so with the flag
    /// off, or no key sealed, nothing about routing or the adapter changes.
    static func load(from reader: ConfigReader) -> AnthropicManagedTrialConfig? {
        guard reader.bool(forKey: ConfigKey("anthropic.first"), default: false) else { return nil }
        let apiKey = resolveAPIKey(from: reader)
        guard !apiKey.isEmpty else { return nil }

        let model = trimmed(reader.string(forKey: ConfigKey("anthropic.model"), default: ""))
        let effort = trimmed(reader.string(forKey: ConfigKey("anthropic.effort"), default: "")).lowercased()
        let thinking = trimmed(reader.string(forKey: ConfigKey("anthropic.thinking"), default: "")).lowercased()
        let scope = trimmed(reader.string(forKey: ConfigKey("anthropic.scope"), default: "")).lowercased()
        return AnthropicManagedTrialConfig(
            apiKey: apiKey,
            model: model.isEmpty ? defaultModel : model,
            effort: efforts.contains(effort) ? effort : nil,
            thinking: Thinking(rawValue: thinking) ?? .adaptive,
            scope: Scope(rawValue: scope) ?? .all
        )
    }

    /// Canonical provider key → legacy spelling → `ANTHROPIC_API_KEY`.
    ///
    /// A deployment that already enables Anthropic in the registry keeps
    /// spending that key; the trial alias only fills the gap when it is unset.
    static func resolveAPIKey(from reader: ConfigReader) -> String {
        [
            ProviderRegistry.apiKeyConfigKey("anthropic"),
            ProviderRegistry.legacyAPIKeyConfigKey("anthropic"),
            "anthropic.apiKey",
        ]
        .lazy
        .map { trimmed(reader.string(forKey: ConfigKey($0), isSecret: true, default: "")) }
        .first { !$0.isEmpty } ?? ""
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
