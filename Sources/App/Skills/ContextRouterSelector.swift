import Foundation
import Hummingbird
import Logging

/// HER-172 selector — given the user's chat message and a list of
/// `SkillManifest`s, ask a `capability=low` model "which (if any) of
/// these is relevant?" and return at most one match.
///
/// Latency budget: < 300 ms p95 (Gemini Flash / similar). The single-shot
/// chat call is the only network hop. A hard timeout keeps a slow upstream
/// from blocking the user's chat.
///
/// Selector is intentionally **structurally bounded**:
/// - Returns at most ONE skill name (HER-172 acceptance: no cascading
///   prompt bloat).
/// - Empty manifest list → returns `nil` without an LLM call.
/// - Any selector failure → returns `nil`; middleware falls through with
///   the original request. ContextRouter must never break chat.
protocol ContextRouterSelector: Sendable {
    /// Returns the manifest the selector picked, or `nil` if no skill is
    /// relevant. Implementations MUST swallow upstream errors and return
    /// `nil` rather than throw — chat is the hot path.
    func selectSkill(
        for userMessage: String,
        manifests: [SkillManifest],
        timeout: Duration
    ) async -> SkillManifest?
}

/// Default selector — drives the chat against the same Hermes transport
/// the rest of the LLM surface uses, with a `low` capability profile.
/// The model is asked to return ONLY the skill name on a line of its
/// own, or `NONE`. Anything else is treated as `NONE`.
struct DefaultContextRouterSelector: ContextRouterSelector {
    let transport: any HermesChatTransport
    let model: String
    let profileUsername: String
    let logger: Logger

    init(
        transport: any HermesChatTransport,
        model: String,
        profileUsername: String,
        logger: Logger
    ) {
        self.transport = transport
        self.model = model
        self.profileUsername = profileUsername
        self.logger = logger
    }

    func selectSkill(
        for userMessage: String,
        manifests: [SkillManifest],
        timeout: Duration = .milliseconds(300)
    ) async -> SkillManifest? {
        guard !manifests.isEmpty else { return nil }
        guard !userMessage.isEmpty else { return nil }

        // Build the catalog block. Each skill on its own line: `name — description`.
        let catalog = manifests
            .map { "\($0.name) — \($0.description)" }
            .joined(separator: "\n")

        let systemPrompt = """
            You route an incoming chat message to ONE of the user's skills,
            or NONE. Respond with EXACTLY one token: the skill name from the
            catalog below, or the literal word NONE. No prose, no
            punctuation, no explanation.
            """
        let userPrompt = """
            Catalog:
            \(catalog)

            Message:
            \(userMessage)

            Reply with one of: \(manifests.map(\.name).joined(separator: ", ")), NONE.
            """

        let body = OAIRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ],
            temperature: 0,
            stream: false
        )
        let payload: Data
        do {
            payload = try JSONEncoder().encode(body)
        } catch {
            return nil
        }

        let raw: Data
        do {
            // Hard timeout per HER-172 latency budget. Cancel the upstream
            // call rather than block the user's chat.
            raw = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { [transport, profileUsername] in
                    try await transport.chatCompletions(payload: payload, profileUsername: profileUsername)
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    throw ContextRouterError.timedOut
                }
                guard let first = try await group.next() else {
                    throw ContextRouterError.noResponse
                }
                group.cancelAll()
                return first
            }
        } catch {
            logger.debug("context-routing selector: upstream failed, no-op (\(error))")
            return nil
        }

        let response: OAIResponse
        do {
            response = try JSONDecoder().decode(OAIResponse.self, from: raw)
        } catch {
            return nil
        }

        let assistantContent = response.choices.first?.message.content ?? ""
        let token = assistantContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .first ?? ""
        guard !token.isEmpty, token.uppercased() != "NONE" else {
            return nil
        }
        return manifests.first(where: { $0.name == token })
    }

    // MARK: - Wire shapes

    private struct OAIMessage: Codable {
        let role: String
        let content: String
    }
    private struct OAIRequest: Codable {
        let model: String
        let messages: [OAIMessage]
        let temperature: Double
        let stream: Bool
    }
    private struct OAIChoice: Codable {
        struct Message: Codable { let role: String; let content: String? }
        let message: Message
    }
    private struct OAIResponse: Codable {
        let choices: [OAIChoice]
    }
}

enum ContextRouterError: Error {
    case timedOut
    case noResponse
}
