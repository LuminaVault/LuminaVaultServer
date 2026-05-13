import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

/// HER-146 outcome of a single per-user correlation run.
enum HealthCorrelationOutcome: Equatable {
    /// Synthesis succeeded; the new memory row was saved.
    case saved(memoryID: UUID)
    /// User has <30 days of `health_events` — too little signal for correlation.
    case skippedInsufficientHistory
    /// User already has a `correlation`+`weekly` memory created within the
    /// run interval (default 7 days). Re-runs the same week are no-ops.
    case skippedAlreadyRanThisWeek
    /// No `health_events` in the lookback window — nothing to correlate against.
    case skippedNoRecentEvents
    /// Hermes returned an empty assistant message; nothing worth persisting.
    case skippedNoSynthesis
}

/// HER-146 Apple Health correlation engine.
///
/// Once per week per user, hand Hermes the user's last 7 days of
/// `health_events` plus their last 7 days of `memories`, ask for
/// cross-modal correlations ("you slept worse the nights after the long
/// runs"), and persist the single synthesized response as a memory
/// tagged `correlation` + `weekly`.
///
/// Idempotent at the per-week granularity: if a `correlation`+`weekly`
/// memory already exists for the tenant within the last `runIntervalDays`,
/// the run is a no-op. The cron driver doesn't need to remember per-user
/// last-run state.
///
/// Single-shot chat is intentional (not an agent loop with tool calls)
/// for the MVP scaffold — the future direction is the skills system
/// (HER-148) supersedes this with a generic weekly-review skill that has
/// `session_search` available. Keeps the present blast radius small.
actor HealthCorrelationService {
    let transport: any HermesChatTransport
    let fluent: Fluent
    let embeddings: any EmbeddingService
    let memories: MemoryRepository
    let defaultModel: String
    let logger: Logger

    /// Minimum days of `health_events` history before we run. Mirrors the
    /// HER-146 acceptance: skip users with <30 days of HealthKit data.
    let minHealthHistoryDays: Int
    /// How far back we look for health events + memories on each run.
    let lookbackDays: Int
    /// Idempotency window. We refuse to write a second
    /// `correlation`+`weekly` memory inside this window for the same user.
    let runIntervalDays: Int

    init(
        transport: any HermesChatTransport,
        fluent: Fluent,
        embeddings: any EmbeddingService,
        memories: MemoryRepository,
        defaultModel: String,
        logger: Logger,
        minHealthHistoryDays: Int = 30,
        lookbackDays: Int = 7,
        runIntervalDays: Int = 7,
    ) {
        self.transport = transport
        self.fluent = fluent
        self.embeddings = embeddings
        self.memories = memories
        self.defaultModel = defaultModel
        self.logger = logger
        self.minHealthHistoryDays = minHealthHistoryDays
        self.lookbackDays = lookbackDays
        self.runIntervalDays = runIntervalDays
    }

    func correlate(user: User, now: Date = Date()) async throws -> HealthCorrelationOutcome {
        let tenantID = try user.requireID()
        let db = fluent.db()

        // 1) Idempotency: bail if we already wrote a correlation memory this week.
        if try await hasRecentCorrelationMemory(tenantID: tenantID, now: now) {
            return .skippedAlreadyRanThisWeek
        }

        // 2) Skip users with <minHealthHistoryDays of HealthKit data.
        let historyCutoff = now.addingTimeInterval(-TimeInterval(minHealthHistoryDays) * 86400)
        let oldestEvent = try await HealthEvent.query(on: db, tenantID: tenantID)
            .sort(\.$recordedAt, .ascending)
            .first()
        guard let oldestEvent, oldestEvent.recordedAt <= historyCutoff else {
            return .skippedInsufficientHistory
        }

        // 3) Pull the rolling window.
        let windowStart = now.addingTimeInterval(-TimeInterval(lookbackDays) * 86400)
        let events = try await HealthEvent.query(on: db, tenantID: tenantID)
            .filter(\.$recordedAt >= windowStart)
            .sort(\.$recordedAt, .ascending)
            .all()
        guard !events.isEmpty else {
            return .skippedNoRecentEvents
        }
        let recentMemories = try await Memory.query(on: db, tenantID: tenantID)
            .filter(\.$createdAt >= windowStart)
            .sort(\.$createdAt, .ascending)
            .all()

        // 4) Ask Hermes.
        let prompt = Self.buildUserPrompt(events: events, memories: recentMemories, now: now)
        let synthesis = try await callHermes(prompt: prompt, profileUsername: user.username)
        let trimmed = synthesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .skippedNoSynthesis
        }

        // 5) Persist as a tagged memory so it shows up in semantic search.
        let embedding = try await embeddings.embed(trimmed)
        let memory = try await memories.create(
            tenantID: tenantID,
            content: trimmed,
            embedding: embedding,
            tags: ["correlation", "weekly"],
        )
        let id = try memory.requireID()
        logger.info("health correlation saved tenant=\(tenantID) memory=\(id) eventCount=\(events.count) memoryCount=\(recentMemories.count)")
        return .saved(memoryID: id)
    }

    // MARK: - Idempotency probe

    /// Looks for any memory tagged `correlation` created inside the
    /// per-user run interval. Uses raw SQL because Fluent has no native
    /// operator for `= ANY(tags)` on a TEXT[] column; the GIN index on
    /// `tags` (M18) keeps this lookup cheap.
    private func hasRecentCorrelationMemory(tenantID: UUID, now: Date) async throws -> Bool {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for tag probe")
        }
        let cutoff = now.addingTimeInterval(-TimeInterval(runIntervalDays) * 86400)
        struct Row: Decodable { let id: UUID }
        let rows = try await sql.raw("""
        SELECT id FROM memories
        WHERE tenant_id = \(bind: tenantID)
          AND created_at >= \(bind: cutoff)
          AND 'correlation' = ANY(tags)
        LIMIT 1
        """).all(decoding: Row.self)
        return !rows.isEmpty
    }

    // MARK: - Hermes call

    private struct OAIChatMessage: Encodable { let role: String; let content: String }
    private struct OAIChatRequestBody: Encodable {
        let model: String
        let messages: [OAIChatMessage]
        let temperature: Double
        let stream: Bool
    }

    private struct OAIChatResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let role: String; let content: String? }
            let message: Message
        }

        let choices: [Choice]
    }

    private func callHermes(prompt: String, profileUsername: String) async throws -> String {
        let body = OAIChatRequestBody(
            model: defaultModel,
            messages: [
                OAIChatMessage(role: "system", content: Self.systemPrompt),
                OAIChatMessage(role: "user", content: prompt),
            ],
            temperature: 0.3,
            stream: false,
        )
        let payload = try JSONEncoder().encode(body)
        let raw = try await transport.chatCompletions(payload: payload, profileUsername: profileUsername)
        let response = try JSONDecoder().decode(OAIChatResponseBody.self, from: raw)
        return response.choices.first?.message.content ?? ""
    }

    // MARK: - Prompt construction

    private static let systemPrompt = """
    You are Hermes, a private second brain. Your job is to find concrete
    correlations between the user's last 7 days of health metrics and
    their captured notes / thoughts.

    Output rules:
    * Single tight paragraph followed by a `- ` bullet list of 2-5
      concrete correlations. No headers, no preamble, no apologies.
    * Each bullet pairs a health observation with a note observation
      using the format: `When X happened in the metrics, Y appeared in
      the notes.`
    * Only assert a correlation if both sides actually appear in the
      input data. Do NOT invent metrics or notes.
    * If there is no plausible correlation, respond with EXACTLY the
      single line `NO_CORRELATION` — the caller treats it as a skip.
    """

    static func buildUserPrompt(events: [HealthEvent], memories: [Memory], now: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var s = "Window ending \(iso.string(from: now)) (last 7 days).\n\n"
        s += "## Health events (\(events.count))\n"
        for ev in events {
            let recorded = iso.string(from: ev.recordedAt)
            let value: String = if let n = ev.valueNumeric {
                ev.unit.map { "\(n) \($0)" } ?? String(n)
            } else if let t = ev.valueText {
                t
            } else {
                "?"
            }
            s += "- [\(recorded)] \(ev.eventType): \(value)\n"
        }
        s += "\n## Memories (\(memories.count))\n"
        for m in memories {
            let stamp = m.createdAt.map { iso.string(from: $0) } ?? "?"
            // Keep each memory line bounded so the prompt doesn't blow up.
            let trimmed = m.content.prefix(280).replacingOccurrences(of: "\n", with: " ")
            s += "- [\(stamp)] \(trimmed)\n"
        }
        s += "\nFind correlations. Respond per system instructions."
        return s
    }
}
