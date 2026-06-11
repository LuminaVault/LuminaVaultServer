import Foundation
import LuminaVaultShared

/// Lumina Jobs P3 — classifies a chat message for recurring-job intent.
/// A cheap, single-shot LLM call: given the user's text, decide whether they
/// asked to set up a scheduled/recurring job and, if so, extract the cron,
/// title, domain, and spec. Always fails *closed* (returns `isJob: false`) so
/// a classifier hiccup never blocks normal chat.
struct JobIntentClassifier {
    let transport: any HermesChatTransport
    let model: String

    func classify(text: String, tenantID: UUID) async -> JobProposalDTO {
        let system = """
        You classify whether a user's message is a request to set up a RECURRING / \
        scheduled job — daily/weekly/etc. monitoring, alerts, digests, summaries — \
        as opposed to a one-off question or a note to save.

        Respond with ONLY a JSON object (no prose, no code fence):
        {"isJob": true|false, "title": "<short title>", "cron": "<crontab, e.g. 0 8 * * *>",
         "scheduleHuman": "<e.g. Every day at 8:00 AM>",
         "domain": "stocks|sports|ai|tech|health|news|finance|life|other",
         "spec": "<imperative description of what to produce each run>"}

        If it is NOT a recurring job, return exactly {"isJob": false}.
        Infer a sensible cron from natural language ("every morning" → 0 8 * * *,
        "weekly" → 0 9 * * 1). Keep the spec self-contained — it becomes the job's
        instructions and will run without the original conversation.
        """
        let messages = [
            AgentMessage(role: "system", content: system),
            AgentMessage(role: "user", content: text),
        ]
        let body = ChatRequestBody(model: model, messages: messages, temperature: 0.1, stream: false)
        guard let payload = try? JSONEncoder().encode(body),
              let meta = try? await transport.chatCompletionsWithMetadata(
                  payload: payload, sessionKey: tenantID.uuidString, sessionID: nil
              ),
              let response = try? JSONDecoder().decode(ChatResponseBody.self, from: meta.data),
              let content = response.choices.first?.message.content
        else {
            return JobProposalDTO(isJob: false)
        }
        return Self.parse(content)
    }

    /// Pure, testable: parse the classifier's JSON (tolerating a ```json fence)
    /// into a proposal. Anything unparseable → not a job.
    static func parse(_ content: String) -> JobProposalDTO {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let unfenced: String = {
            guard trimmed.hasPrefix("```") else { return trimmed }
            let afterTag = trimmed.drop(while: { $0 == "`" }).drop(while: { $0 != "\n" }).dropFirst()
            if let end = afterTag.range(of: "```", options: .backwards) {
                return String(afterTag[afterTag.startIndex ..< end.lowerBound])
            }
            return String(afterTag)
        }()
        guard let data = unfenced.data(using: .utf8),
              let env = try? JSONDecoder().decode(Envelope.self, from: data),
              env.isJob == true
        else {
            return JobProposalDTO(isJob: false)
        }
        return JobProposalDTO(
            isJob: true,
            title: env.title,
            cron: env.cron,
            scheduleHuman: env.scheduleHuman,
            domain: env.domain,
            spec: env.spec
        )
    }

    private struct Envelope: Decodable {
        let isJob: Bool?
        let title: String?
        let cron: String?
        let scheduleHuman: String?
        let domain: String?
        let spec: String?
    }

    /// Minimal OpenAI-compatible chat DTOs (each service owns its own).
    private struct AgentMessage: Codable {
        let role: String
        let content: String?
    }

    private struct ChatRequestBody: Encodable {
        let model: String
        let messages: [AgentMessage]
        let temperature: Double?
        let stream: Bool
    }

    private struct ChatResponseChoice: Decodable { let message: AgentMessage }
    private struct ChatResponseBody: Decodable { let choices: [ChatResponseChoice] }
}
