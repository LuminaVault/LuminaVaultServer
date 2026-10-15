import Foundation
import Logging
import LuminaVaultShared

/// Decides whether an assistant reply is worth keeping as a memory.
///
/// `MemoryIndexWorker` used to store every final reply, so a vault filled up
/// with how-to answers and small talk that then competed with what the user
/// actually said. The judge asks one narrow question about one reply and
/// answers keep / don't keep (plus a kind). It never writes memory text.
protocol MemoryKeepJudge: Sendable {
    func judge(content: String, tenantID: UUID) async throws -> MemoryKeepDecision
}

struct MemoryKeepDecision: Equatable {
    let keep: Bool
    let kind: MemoryKindDTO?

    static let keepUnclassified = Self(keep: true, kind: nil)
}

/// The judge on the managed provider chain (the Haiku trial routes first).
///
/// BYOK tenants are never judged: their replies went to their own provider,
/// and judging would send that text to the managed model. They keep the old
/// behaviour, every reply stored. No temperature is sent — Haiku 5.5 rejects
/// non-default sampling parameters (platform/infra docs/llm-haiku-trial.md).
struct LLMMemoryKeepJudge: MemoryKeepJudge {
    let transport: any HermesChatTransport
    let preferences: UserLLMPreferenceRepository?
    let model: String
    let logger: Logger

    static let maxChars = 4000

    func judge(content: String, tenantID: UUID) async throws -> MemoryKeepDecision {
        if let preferences, let pref = try? await preferences.get(tenantID: tenantID), pref.mode == .byok {
            return .keepUnclassified
        }
        let system = """
        You read one answer an assistant gave its user, and decide whether it \
        records something durable about the user worth recalling in a later \
        session: a preference, a decision they made, or a lasting fact about \
        them or their work. General knowledge, explanations, how-to answers, \
        greetings, and anything only useful in this conversation are not \
        durable. Return ONLY JSON: {"keep": true|false, "kind": \
        "preference"|"decision"|"fact"|null}.
        """
        let payload = Payload(
            model: model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: String(content.prefix(Self.maxChars))),
            ]
        )
        let raw = try await transport.chatCompletions(
            payload: JSONEncoder().encode(payload),
            sessionKey: tenantID.uuidString,
            sessionID: nil
        )
        let text = try JSONDecoder().decode(Response.self, from: raw).choices.first?.message.content ?? ""
        return Self.parse(text) ?? .keepUnclassified
    }

    /// Lenient parse; nil when the reply has no usable verdict, which the
    /// caller treats as "keep" — the gate fails open, never losing a reply.
    static func parse(_ raw: String) -> MemoryKeepDecision? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lo = s.firstIndex(of: "{"), let hi = s.lastIndex(of: "}"), lo < hi {
            s = String(s[lo ... hi])
        }
        guard let data = s.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keep = object["keep"] as? Bool
        else { return nil }
        let kind = (object["kind"] as? String).flatMap(MemoryKindDTO.init(rawValue:))
        return MemoryKeepDecision(keep: keep, kind: keep ? kind : nil)
    }

    private struct Payload: Encodable {
        let model: String
        let messages: [Message]
        let stream = false
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct Response: Decodable {
        struct Choice: Decodable { let message: ChoiceMessage }
        struct ChoiceMessage: Decodable { let content: String? }
        let choices: [Choice]
    }
}
