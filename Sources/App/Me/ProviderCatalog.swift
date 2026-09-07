import Foundation
import LuminaVaultShared

/// Static, per-provider facts a client needs to render a BYO key form.
///
/// This existed only as hardcoded copies in the iOS and web clients — display
/// names, default endpoints, which providers need a base URL, what their keys
/// look like. Adding a provider therefore touched three repositories, and the
/// copies drifted: a provider could be spendable by the router while a client
/// still showed it as unavailable, or offer a base-URL field for a provider
/// that ignores one.
///
/// Serving it from the server puts the facts next to the adapters that
/// actually implement them, and lets `available` reflect the *deployment*
/// rather than a client's build.
enum ProviderCatalog {
    static func entry(for provider: ProviderID) -> ProviderCatalogEntryDTO {
        switch provider {
        case .xai:
            .init(
                provider: .xai,
                displayName: "xAI",
                defaultBaseURL: "https://api.x.ai/v1",
                keyHint: "xai-...",
                keysURL: "https://console.x.ai"
            )
        case .anthropic:
            .init(
                provider: .anthropic,
                displayName: "Anthropic",
                defaultBaseURL: "https://api.anthropic.com",
                keyHint: "sk-ant-...",
                keysURL: "https://console.anthropic.com/settings/keys"
            )
        case .openai:
            .init(
                provider: .openai,
                displayName: "OpenAI",
                defaultBaseURL: "https://api.openai.com/v1",
                keyHint: "sk-...",
                keysURL: "https://platform.openai.com/api-keys"
            )
        case .ollama:
            // Addresses a server the user runs, which commonly has no auth at
            // all — so the base URL is the credential and the key is optional.
            .init(
                provider: .ollama,
                displayName: "Ollama",
                defaultBaseURL: "http://localhost:11434",
                requiresBaseURL: true,
                requiresAPIKey: false,
                keysURL: "https://ollama.com/download"
            )
        case .openRouter:
            .init(
                provider: .openRouter,
                displayName: "OpenRouter",
                defaultBaseURL: "https://openrouter.ai/api/v1",
                keyHint: "sk-or-v1-...",
                keysURL: "https://openrouter.ai/keys"
            )
        case .nvidia:
            .init(
                provider: .nvidia,
                displayName: "NVIDIA NIM",
                defaultBaseURL: "https://integrate.api.nvidia.com/v1",
                keyHint: "nvapi-...",
                keysURL: "https://build.nvidia.com"
            )
        case .gemini:
            .init(
                provider: .gemini,
                displayName: "Google Gemini",
                defaultBaseURL: "https://generativelanguage.googleapis.com",
                keyHint: "AIza...",
                keysURL: "https://aistudio.google.com/apikey"
            )
        case .nous:
            .init(
                provider: .nous,
                displayName: "Nous Research",
                defaultBaseURL: "https://inference-api.nousresearch.com/v1",
                keysURL: "https://portal.nousresearch.com"
            )
        case .custom:
            // No default endpoint by definition: the whole point is that the
            // user supplies one. A key is optional because a self-hosted
            // OpenAI-compatible server often has no auth.
            .init(
                provider: .custom,
                displayName: "Custom (OpenAI-compatible)",
                defaultBaseURL: nil,
                requiresBaseURL: true,
                requiresAPIKey: false
            )
        }
    }

    /// The catalog for this deployment. `available` is false for a provider
    /// with no registered adapter, so a client does not offer to collect a key
    /// that nothing here can spend.
    static func all(available: (ProviderID) -> Bool = { _ in true }) -> [ProviderCatalogEntryDTO] {
        ProviderID.allCases.map { id in
            let base = entry(for: id)
            return ProviderCatalogEntryDTO(
                provider: base.provider,
                displayName: base.displayName,
                defaultBaseURL: base.defaultBaseURL,
                requiresBaseURL: base.requiresBaseURL,
                requiresAPIKey: base.requiresAPIKey,
                keyHint: base.keyHint,
                keysURL: base.keysURL,
                available: available(id)
            )
        }
    }
}
