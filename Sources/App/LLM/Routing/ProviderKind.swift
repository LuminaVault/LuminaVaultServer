import Foundation

/// HER-165 routing primitive — identifies the upstream we route a chat
/// call to. One enum case per `ProviderAdapter` implementation.
///
/// `hermesGateway` is the in-VPS Hermes container today; everything else
/// is reserved for HER-161..HER-164 adapter tickets. Cases are stable on
/// the wire (the `rawValue` is used in logs + metrics labels), so do NOT
/// rename — add new cases instead.
enum ProviderKind: String, Sendable, Hashable, CaseIterable, Codable {
    case hermesGateway
    case together
    case groq
    case openRouter
    case deepseek
    case kimi
    case gemini
    case openai
    case anthropic
    case ollama
}
