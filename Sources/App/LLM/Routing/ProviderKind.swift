import Foundation

/// HER-165 routing primitive — identifies the upstream we route a chat
/// call to. One enum case per `ProviderAdapter` implementation.
///
/// `hermesGateway` is the in-VPS Hermes container today; everything else
/// is reserved for HER-161..HER-164 adapter tickets. Cases are stable on
/// the wire (the `rawValue` is used in logs + metrics labels), so do NOT
/// rename — add new cases instead.
enum ProviderKind: String, Hashable, CaseIterable, Codable {
    case hermesGateway
    case anthropic
    case openai
    case gemini
    case together
    case groq
    case fireworks
    case deepInfra
    case deepseekDirect
    case openRouter
    case deepseek
    case kimi
    case ollama
    /// HER-252 — direct xAI API-key path (`https://api.x.ai/v1/...`),
    /// distinct from the OAuth container path that routes through
    /// `.hermesGateway`. Adapter is the OpenAI-compatible one with a
    /// per-user `Authorization: Bearer <xai-key>` resolved from
    /// `user_provider_credentials`.
    case xai

    /// NVIDIA NIM — OpenAI-compatible API-key path
    /// (`https://integrate.api.nvidia.com/v1/...`). Adapter is the
    /// OpenAI-compatible one with a per-user `Authorization: Bearer <nvapi-key>`
    /// resolved from `user_provider_credentials`. US-hosted.
    case nvidia

    /// Nous Research portal inference API — OpenAI-compatible
    /// (`https://inference-api.nousresearch.com/v1/...`). Adapter is the
    /// OpenAI-compatible one with a per-user `Authorization: Bearer <key>`
    /// resolved from `user_provider_credentials`. US-hosted. Distinct from
    /// the container-scoped Nous OAuth flow routed via `.hermesGateway`.
    case nous

    /// P2 — generic OpenAI-compatible endpoint. User supplies base URL +
    /// optional key; routed via the OpenAI-compatible adapter. Covers
    /// Groq, Together, LM Studio, vLLM, LiteLLM, llama.cpp server. Because
    /// self-hosted instances often live on private/LAN addresses, its
    /// SSRF policy is opt-in per credential (see ProvidersController).
    case custom

    /// HER-164 — hosting / weight-origin region tag used by the privacy
    /// filter to exclude `.cn` providers when `privacy_no_cn_origin=true`.
    /// `deepseek` (non-direct) and `deepseekDirect` are both Chinese-hosted
    /// inference endpoints. Together / Groq / Fireworks / DeepInfra host
    /// CN-origin *weights* on US infra — they stay `.us` here; the
    /// model-identifier substring filter in `ModelOriginRegistry` covers
    /// weight-origin exclusion.
    var region: ModelOrigin {
        switch self {
        case .deepseek, .deepseekDirect, .kimi: .cn
        default: .us
        }
    }
}

extension ProviderKind {
    /// HER-252 — providers that participate in per-user credential
    /// management + user-facing fallback chain. Anything outside this set
    /// is an internal routing target (e.g. `.together` as a deployment
    /// default for free-tier users) and not exposed in the iOS providers
    /// pane / LLM preferences UI.
    static let userCredentialTargets: Set<ProviderKind> = [
        .xai, .anthropic, .openai, .gemini, .openRouter, .ollama, .nvidia, .nous, .custom,
    ]
}

extension ProviderKind {
    /// Whether a stored row is actually *spendable* — i.e. a request built
    /// from it could succeed without a platform key.
    ///
    /// This matters because a usable credential is what earns a tenant the
    /// BYO paywall exemption. The old test was `apiKey != nil || baseURL !=
    /// nil`, which let a row carrying only a base URL count. For every
    /// provider that authenticates, that row cannot buy a single token — it
    /// 401s — so it was proof of nothing, and saving a bare base URL against
    /// any provider unlocked the paid surface.
    ///
    /// `.ollama` and `.custom` are the real exceptions rather than an
    /// oversight: both address a server the user runs, which commonly has no
    /// auth at all, so a base URL alone genuinely is the whole credential.
    static let keylessCapable: Set<ProviderKind> = [.ollama, .custom]

    func isSpendable(apiKey: String?, baseURL: URL?) -> Bool {
        if let apiKey, !apiKey.isEmpty {
            return true
        }
        guard Self.keylessCapable.contains(self) else { return false }
        guard let baseURL, let scheme = baseURL.scheme, !scheme.isEmpty, baseURL.host != nil else {
            return false
        }
        return true
    }
}
