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
