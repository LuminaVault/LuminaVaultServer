import Foundation
import LuminaVaultShared

/// HER-55 — classifies a chat message for reminder intent. A cheap, single-shot
/// LLM call: given the user's text + the current time, decide whether they asked
/// to be reminded of something and, if so, extract the title, body, absolute
/// fire time, and (optionally) a recurrence cron. Always fails *closed* (returns
/// `isReminder: false`) so a classifier hiccup never blocks normal chat.
///
/// Mirrors `JobIntentClassifier`. The distinction the prompt draws:
/// - reminder = a one-shot or recurring *timed nudge* ("remind me to call mom at 5")
/// - job (handled elsewhere) = a recurring task that *produces content* each run
///   (digests, monitors, summaries).
struct ReminderIntentClassifier {
    let transport: any HermesChatTransport
    let model: String

    /// `now` is injected so the model can resolve relative phrasing
    /// ("in an hour", "tomorrow morning") against a concrete instant. The
    /// server treats all times as UTC; the client renders in local time.
    func classify(text: String, tenantID: UUID, now: Date = Date()) async -> ReminderProposalDTO {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let nowString = iso.string(from: now)

        let system = """
        You classify whether a user's message is a request to BE REMINDED of \
        something at a time — a one-shot nudge ("remind me to call mom at 5pm", \
        "ping me in an hour") or a recurring nudge ("remind me to stretch every \
        weekday at 3"). This is distinct from a recurring JOB that produces a \
        report/digest each run — those are NOT reminders.

        The current time is \(nowString) (UTC). Resolve all relative phrasing \
        against it and output absolute UTC times.

        Respond with ONLY a JSON object (no prose, no code fence):
        {"isReminder": true|false,
         "title": "<short imperative title, e.g. Call mom>",
         "body": "<optional extra detail, may be empty>",
         "fireAt": "<ISO 8601 UTC, e.g. 2026-06-09T17:00:00Z>",
         "recurrenceCron": "<crontab if recurring, else omit>",
         "scheduleHuman": "<e.g. Tomorrow at 5:00 PM, or Every weekday at 3:00 PM>"}

        If it is NOT a reminder request, return exactly {"isReminder": false}.
        For recurring reminders, infer a sensible cron ("every weekday at 3" → \
        0 15 * * 1-5) and still set fireAt to the next matching occurrence.
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
            return ReminderProposalDTO(isReminder: false)
        }
        return Self.parse(content)
    }

    /// Pure, testable: parse the classifier's JSON (tolerating a ```json fence)
    /// into a proposal. Anything unparseable, or a fireAt that won't parse, →
    /// not a reminder.
    static func parse(_ content: String) -> ReminderProposalDTO {
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
              env.isReminder == true,
              let fireAtRaw = env.fireAt,
              let fireAt = Self.parseDate(fireAtRaw)
        else {
            return ReminderProposalDTO(isReminder: false)
        }
        let cron = (env.recurrenceCron?.isEmpty == false) ? env.recurrenceCron : nil
        return ReminderProposalDTO(
            isReminder: true,
            title: env.title,
            body: env.body ?? "",
            fireAt: fireAt,
            recurrenceCron: cron,
            scheduleHuman: env.scheduleHuman
        )
    }

    /// Lenient ISO 8601 parse — accepts both with and without fractional seconds.
    static func parseDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private struct Envelope: Decodable {
        let isReminder: Bool?
        let title: String?
        let body: String?
        let fireAt: String?
        let recurrenceCron: String?
        let scheduleHuman: String?
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
