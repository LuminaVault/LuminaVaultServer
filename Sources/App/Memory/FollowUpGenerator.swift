import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

/// HER-37 Slice C — server-generated follow-up chips for the Think tab.
///
/// Runs a single, bounded Hermes call against the assistant's just-produced
/// summary + top source titles and returns 3–5 short imperative
/// follow-ups. Crucially **defensive** — any failure (upstream error,
/// malformed JSON, empty array) returns `[]` rather than throwing, so a
/// flaky follow-up generator can never abort a parent `/v1/query/stream`
/// or `/v1/conversations/.../messages/stream` response.
struct FollowUpGenerator {
    let transport: any HermesChatTransport
    let defaultModel: String
    let logger: Logger
    /// Soft ceiling — the generator caps its output at this many entries
    /// regardless of model behaviour.
    let maxFollowUps: Int

    init(
        transport: any HermesChatTransport,
        defaultModel: String,
        logger: Logger,
        maxFollowUps: Int = 4,
    ) {
        self.transport = transport
        self.defaultModel = defaultModel
        self.logger = logger
        self.maxFollowUps = maxFollowUps
    }

    /// Returns 0–`maxFollowUps` follow-up chip strings. Never throws.
    func generate(
        sessionKey: String,
        sessionID: String? = nil,
        summary: String,
        sources: [QueryHitDTO],
    ) async -> [String] {
        // Skip the call entirely when there's nothing to riff on — keeps
        // latency in check on empty-hit / blank-summary queries.
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSummary.isEmpty, sources.isEmpty {
            return []
        }

        let prompt = Self.buildPrompt(summary: trimmedSummary, sources: sources, max: maxFollowUps)
        let body = OutboundBody(
            model: defaultModel,
            messages: prompt,
            temperature: 0.5,
            response_format: .init(type: "json_object"),
            stream: false,
        )

        let payload: Data
        do {
            payload = try JSONEncoder().encode(body)
        } catch {
            logger.warning("follow-up generator encode failed: \(error)")
            return []
        }

        let response: Data
        do {
            response = try await transport.chatCompletions(payload: payload, sessionKey: sessionKey, sessionID: sessionID)
        } catch {
            logger.warning("follow-up generator upstream failed: \(error)")
            return []
        }

        guard let parsed = Self.parse(response: response) else {
            logger.debug("follow-up generator returned unparseable response")
            return []
        }
        return Array(parsed.prefix(maxFollowUps))
    }

    // MARK: - Prompt construction

    /// Builds a minimal system + user prompt. Source contents are
    /// truncated to ~120 characters each so the prompt stays well under
    /// typical context limits even with 5 hits.
    static func buildPrompt(summary: String, sources: [QueryHitDTO], max: Int) -> [ChatMessage] {
        let sourceLines: String = if sources.isEmpty {
            "(no source notes were used)"
        } else {
            sources.enumerated().map { offset, hit in
                let snippet = hit.content.prefix(120).trimmingCharacters(in: .whitespacesAndNewlines)
                return "[\(offset + 1)] \(snippet)"
            }.joined(separator: "\n")
        }

        let user = """
        Lumina just answered the user. Suggest \(max) short follow-up
        prompts they might ask next, in their voice (first person, present
        tense). Each must be ≤ 60 characters and end with a question mark
        OR an imperative verb (e.g. "Go deeper", "Compare with last month").
        Reply ONLY with JSON of the shape:

            {"follow_ups": ["...", "..."]}

        Do not add commentary, markdown, or extra keys.

        Assistant's answer:
        \(summary.isEmpty ? "(empty)" : summary)

        Notes Lumina used:
        \(sourceLines)
        """

        return [
            ChatMessage(role: "system", content: """
            You generate short, on-brand follow-up prompts for the Think
            tab. You never invent facts; only riff on what was just said.
            """),
            ChatMessage(role: "user", content: user),
        ]
    }

    // MARK: - Response parsing

    /// Extracts the assistant message content from an OpenAI-style chat
    /// completion response, then JSON-parses it into the `follow_ups`
    /// array. Returns `nil` on any structural mismatch.
    static func parse(response: Data) -> [String]? {
        guard let outer = try? JSONDecoder().decode(UpstreamResponse.self, from: response),
              let content = outer.choices.first?.message.content,
              let contentData = content.data(using: .utf8),
              let inner = try? JSONDecoder().decode(FollowUpsBody.self, from: contentData)
        else {
            return nil
        }
        let cleaned = inner.follow_ups
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned
    }
}

// MARK: - Wire types

private struct OutboundBody: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let response_format: ResponseFormat
    let stream: Bool

    struct ResponseFormat: Encodable {
        let type: String
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case response_format
        case stream
    }
}

private struct UpstreamResponse: Decodable {
    struct Choice: Decodable {
        let message: AssistantMessage
    }

    struct AssistantMessage: Decodable {
        let content: String?
    }

    let choices: [Choice]
}

private struct FollowUpsBody: Decodable {
    let follow_ups: [String]
}
