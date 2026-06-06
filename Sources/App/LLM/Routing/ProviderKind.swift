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
        .xai, .anthropic, .openai, .openRouter, .ollama, .nvidia, .nous,
    ]
}
