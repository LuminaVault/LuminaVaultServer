import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import ServiceLifecycle
import SQLKit

/// HER-37 Slice D — proactive synthesis + pattern-detection worker.
///
/// `ServiceLifecycle.Service` that wakes every `tickInterval` (default
/// one hour) and fires two jobs:
///
/// - **Weekly synthesis** — Sunday 02:00 UTC. For each user with
///   ≥1 memory in the last 7 days, ask Hermes for a "Your Brain This
///   Week" headline + summary and insert one `Insight` row with
///   `section=thisWeek`, `periodStart`/`periodEnd` set. Idempotent via
///   a same-period uniqueness check.
///
/// - **Daily pattern detection** — 03:00 UTC. For each user with
///   ≥3 memories in the last 7 days, ask Hermes to surface up to
///   `maxPatternsPerRun` surprising connections and insert one
///   `Insight` row per pattern with `section=patterns`. Skips users
///   whose most recent pattern row is < 24h old.
///
/// - **Daily contradiction detection** — 04:00 UTC. HER-248. Same
///   ≥3-memory gate + 24h cooldown as patterns, but asks Hermes to
///   surface logically incompatible positions on the same subject and
///   inserts one `Insight` row per contradiction with
///   `section=contradictions`.
///
/// Single-replica. Multi-replica = double-fire — add Postgres
/// advisory-lock leader election when scaling out (out of scope for
/// HER-37). Off by default; enable via `SYNTHESIS_WORKER_ENABLED=true`.
actor SynthesisWorker: Service {
    let fluent: Fluent
    let memories: MemoryRepository
    let transport: any HermesChatTransport
    let defaultModel: String
    let logger: Logger
    let tickInterval: Duration
    let maxPatternsPerRun: Int
    let memorySampleSize: Int

    init(
        fluent: Fluent,
        memories: MemoryRepository,
        transport: any HermesChatTransport,
        defaultModel: String,
        logger: Logger,
        tickInterval: Duration = .seconds(3600),
        maxPatternsPerRun: Int = 3,
        memorySampleSize: Int = 30
    ) {
        self.fluent = fluent
        self.memories = memories
        self.transport = transport
        self.defaultModel = defaultModel
        self.logger = logger
        self.tickInterval = tickInterval
        self.maxPatternsPerRun = maxPatternsPerRun
        self.memorySampleSize = memorySampleSize
    }

    func run() async throws {
        logger.info("synthesis.worker started (tick=\(tickInterval))")
        while !Task.isCancelled {
            do { try await tick(at: Date()) }
            catch { logger.warning("synthesis.worker tick error: \(error)") }
            try? await Task.sleep(for: tickInterval)
        }
    }

    /// Single tick. Exposed so tests can drive at specific instants.
    /// Returns counts of (weekly, pattern, contradiction) rows inserted.
    @discardableResult
    func tick(at now: Date) async throws -> (weekly: Int, patterns: Int, contradictions: Int) {
        let hour = Self.hourComponent(of: now)
        let weekday = Self.weekdayComponent(of: now)
        var weekly = 0, patterns = 0, contradictions = 0
        if hour == 2, weekday == 1 {
            weekly = try await runWeeklyForAllUsers(now: now)
        }
        if hour == 3 {
            patterns = try await runPatternsForAllUsers(now: now)
        }
        if hour == 4 {
            contradictions = try await runContradictionsForAllUsers(now: now)
        }
        return (weekly, patterns, contradictions)
    }

    // MARK: - Weekly synthesis

    func runWeeklyForAllUsers(now: Date) async throws -> Int {
        let users = try await User.query(on: fluent.db()).all()
        let window = Self.weeklyWindow(endingAt: now)
        var inserted = 0
        for user in users {
            let tenantID = try user.requireID()
            do {
                if try await runWeeklyJob(tenantID: tenantID, sessionKey: tenantID.uuidString, window: window) {
                    inserted += 1
                }
            } catch {
                logger.warning("synthesis.weekly tenant=\(tenantID) error: \(error)")
            }
        }
        return inserted
    }

    /// Runs the weekly job for a single tenant. Returns `true` when a
    /// row was inserted, `false` when skipped (no memories or
    /// already-synthesised period).
    @discardableResult
    func runWeeklyJob(tenantID: UUID, sessionKey: String, window: Period) async throws -> Bool {
        let existing = try await Insight.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$section == InsightSection.thisWeek.rawValue)
            .filter(\.$periodStart == window.start)
            .filter(\.$periodEnd == window.end)
            .first()
        if existing != nil {
            return false
        }
        let rows = try await loadMemories(tenantID: tenantID, since: window.start, limit: memorySampleSize)
        guard !rows.isEmpty else { return false }
        guard let synth = await synthesise(
            sessionKey: sessionKey,
            prompt: Self.weeklyPrompt(for: rows, window: window)
        ) else { return false }
        let insight = Insight(
            tenantID: tenantID,
            section: .thisWeek,
            headline: synth.headline,
            summary: synth.summary,
            sourceMemoryIDs: rows.map { $0.id ?? UUID() },
            periodStart: window.start,
            periodEnd: window.end
        )
        try await insight.save(on: fluent.db())
        return true
    }

    // MARK: - Pattern detection

    func runPatternsForAllUsers(now: Date) async throws -> Int {
        let users = try await User.query(on: fluent.db()).all()
        var inserted = 0
        for user in users {
            let tenantID = try user.requireID()
            do {
                inserted += try await runPatternJob(tenantID: tenantID, sessionKey: tenantID.uuidString, now: now)
            } catch {
                logger.warning("synthesis.patterns tenant=\(tenantID) error: \(error)")
            }
        }
        return inserted
    }

    /// Pattern job for a single tenant. Returns the number of rows
    /// inserted (0 to `maxPatternsPerRun`). Skips users whose most
    /// recent pattern row is less than 24h old.
    func runPatternJob(tenantID: UUID, sessionKey: String, now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-24 * 3600)
        if let recent = try await Insight.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$section == InsightSection.patterns.rawValue)
            .sort(\.$createdAt, .descending)
            .first(),
            let createdAt = recent.createdAt,
            createdAt > cutoff
        {
            return 0
        }
        let windowStart = now.addingTimeInterval(-7 * 24 * 3600)
        let rows = try await loadMemories(tenantID: tenantID, since: windowStart, limit: memorySampleSize)
        guard rows.count >= 3 else { return 0 }
        guard let patterns = await detectPatterns(
            sessionKey: sessionKey,
            prompt: Self.patternsPrompt(for: rows, max: maxPatternsPerRun)
        ), !patterns.isEmpty else { return 0 }
        var inserted = 0
        for pattern in patterns.prefix(maxPatternsPerRun) {
            let insight = Insight(
                tenantID: tenantID,
                section: .patterns,
                headline: pattern.headline,
                summary: pattern.summary,
                sourceMemoryIDs: rows.map { $0.id ?? UUID() }
            )
            try await insight.save(on: fluent.db())
            inserted += 1
        }
        return inserted
    }

    // MARK: - Contradiction detection (HER-248)

    func runContradictionsForAllUsers(now: Date) async throws -> Int {
        let users = try await User.query(on: fluent.db()).all()
        var inserted = 0
        for user in users {
            let tenantID = try user.requireID()
            do {
                inserted += try await runContradictionJob(tenantID: tenantID, sessionKey: tenantID.uuidString, now: now)
            } catch {
                logger.warning("synthesis.contradictions tenant=\(tenantID) error: \(error)")
            }
        }
        return inserted
    }

    /// Contradiction job for a single tenant. Returns the number of rows
    /// inserted (0 to `maxPatternsPerRun`). Skips users whose most recent
    /// contradiction row is less than 24h old. Mirrors `runPatternJob`.
    func runContradictionJob(tenantID: UUID, sessionKey _: String, now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-24 * 3600)
        if let recent = try await Insight.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$section == InsightSection.contradictions.rawValue)
            .sort(\.$createdAt, .descending)
            .first(),
            let createdAt = recent.createdAt,
            createdAt > cutoff
        {
            return 0
        }
        guard let sql = fluent.db() as? any SQLDatabase else { return 0 }
        let contradictions = try await sql.raw("""
        SELECT e.id AS edge_id,
               left_node.label AS left_label,
               right_node.label AS right_label,
               COALESCE(e.rationale, 'Evidence-backed claims use opposing positions.') AS rationale,
               ARRAY_AGG(DISTINCT evidence.memory_id) AS memory_ids
        FROM knowledge_edges e
        JOIN knowledge_nodes left_node ON left_node.id = e.from_node_id
        JOIN knowledge_nodes right_node ON right_node.id = e.to_node_id
        JOIN knowledge_evidence evidence ON evidence.edge_id = e.id
        WHERE e.tenant_id = \(bind: tenantID)
          AND e.predicate = 'contradicts'
          AND e.state IN ('suggested', 'confirmed')
          AND NOT EXISTS (SELECT 1 FROM insights i WHERE i.knowledge_edge_id = e.id)
        GROUP BY e.id, left_node.label, right_node.label, e.rationale, e.confidence
        ORDER BY e.confidence DESC, e.updated_at DESC
        LIMIT \(bind: maxPatternsPerRun)
        """).all(decoding: GraphContradictionRow.self)
        guard contradictions.isEmpty == false else { return 0 }
        var inserted = 0
        for contradiction in contradictions.prefix(maxPatternsPerRun) {
            let insight = Insight(
                tenantID: tenantID,
                section: .contradictions,
                headline: String("\(contradiction.left_label) ↔ \(contradiction.right_label)".prefix(60)),
                summary: contradiction.rationale,
                sourceMemoryIDs: contradiction.memory_ids,
                knowledgeEdgeID: contradiction.edge_id
            )
            try await insight.save(on: fluent.db())
            inserted += 1
        }
        return inserted
    }

    // MARK: - Hermes helpers

    struct Synthesised: Equatable {
        let headline: String
        let summary: String
    }

    /// Defensive wrapper. Returns `nil` on any failure so the
    /// surrounding job can log + continue.
    private func synthesise(sessionKey: String, prompt: [ChatMessage]) async -> Synthesised? {
        let body = OutboundBody(model: defaultModel, messages: prompt, temperature: 0.5, response_format: .init(type: "json_object"), stream: false)
        guard let payload = try? JSONEncoder().encode(body),
              let response = try? await transport.chatCompletions(payload: payload, sessionKey: sessionKey, sessionID: nil)
        else { return nil }
        return Self.parseSynthesis(response: response)
    }

    private func detectPatterns(sessionKey: String, prompt: [ChatMessage]) async -> [Synthesised]? {
        let body = OutboundBody(model: defaultModel, messages: prompt, temperature: 0.5, response_format: .init(type: "json_object"), stream: false)
        guard let payload = try? JSONEncoder().encode(body),
              let response = try? await transport.chatCompletions(payload: payload, sessionKey: sessionKey, sessionID: nil)
        else { return nil }
        return Self.parsePatterns(response: response)
    }

    private func detectContradictions(sessionKey: String, prompt: [ChatMessage]) async -> [Synthesised]? {
        let body = OutboundBody(model: defaultModel, messages: prompt, temperature: 0.5, response_format: .init(type: "json_object"), stream: false)
        guard let payload = try? JSONEncoder().encode(body),
              let response = try? await transport.chatCompletions(payload: payload, sessionKey: sessionKey, sessionID: nil)
        else { return nil }
        return Self.parseContradictions(response: response)
    }

    private func loadMemories(tenantID: UUID, since: Date, limit: Int) async throws -> [Memory] {
        try await Memory.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$createdAt >= since)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()
    }

    // MARK: - Window math

    struct Period: Equatable {
        let start: Date
        let end: Date
    }

    static func weeklyWindow(endingAt now: Date) -> Period {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let endOfDay = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -7, to: endOfDay) ?? endOfDay
        return Period(start: start, end: endOfDay)
    }

    static func hourComponent(of date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.component(.hour, from: date)
    }

    /// 1 = Sunday in `Calendar.gregorian`.
    static func weekdayComponent(of date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.component(.weekday, from: date)
    }

    // MARK: - Prompts

    static func weeklyPrompt(for memories: [Memory], window: Period) -> [ChatMessage] {
        let context = renderMemoryList(memories)
        return [
            ChatMessage(role: "system", content: "You are Lumina synthesising the user's week. You are concise, grounded, and never invent detail."),
            ChatMessage(role: "user", content: """
            Synthesise the user's week (\(window.start)…\(window.end)) from these memories. Reply ONLY with JSON: {"headline": "...", "summary": "..."}
            - headline ≤ 60 chars, in the user's voice.
            - summary ≤ 600 chars, 1-3 sentences. Cite memories by bracket number.
            - Do NOT invent facts.
            Memories:
            \(context)
            """),
        ]
    }

    static func patternsPrompt(for memories: [Memory], max: Int) -> [ChatMessage] {
        let context = renderMemoryList(memories)
        return [
            ChatMessage(role: "system", content: "You spot non-obvious patterns. You never invent or exaggerate; absence of a pattern is a valid answer."),
            ChatMessage(role: "user", content: """
            Spot up to \(max) surprising cross-cutting patterns. Each must connect ≥2 memories from different topics. Reply ONLY with JSON: {"patterns": [{"headline": "...", "summary": "..."}, ...]}
            - Each headline ≤ 60 chars.
            - Each summary ≤ 400 chars.
            - If no real pattern exists, return {"patterns": []}.
            Memories:
            \(context)
            """),
        ]
    }

    static func contradictionsPrompt(for memories: [Memory], max: Int) -> [ChatMessage] {
        let context = renderMemoryList(memories)
        return [
            ChatMessage(role: "system", content: "You surface genuine contradictions in someone's own thinking. You never invent or exaggerate; a contradiction must survive a sympathetic reading. Absence of a contradiction is a valid answer."),
            ChatMessage(role: "user", content: """
            Find up to \(max) pairs of logically incompatible positions the user has taken on the SAME subject. Each must cite ≥2 memories. Reply ONLY with JSON: {"contradictions": [{"headline": "...", "summary": "..."}, ...]}
            - Each headline ≤ 60 chars, naming the subject in tension.
            - Each summary ≤ 400 chars: state both positions plainly, cite memories by bracket number. Do NOT moralise or resolve it.
            - If there is no real contradiction, return {"contradictions": []}.
            Memories:
            \(context)
            """),
        ]
    }

    private static func renderMemoryList(_ memories: [Memory]) -> String {
        memories.enumerated().map { offset, mem in
            let snippet = mem.content.prefix(180).trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(offset + 1)] \(snippet)"
        }.joined(separator: "\n")
    }

    // MARK: - Parsing

    static func parseSynthesis(response: Data) -> Synthesised? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response),
              let content = envelope.choices.first?.message.content,
              let data = content.data(using: .utf8),
              let inner = try? JSONDecoder().decode(SynthesisBody.self, from: data)
        else { return nil }
        let h = inner.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = inner.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !s.isEmpty else { return nil }
        return Synthesised(headline: h, summary: s)
    }

    static func parsePatterns(response: Data) -> [Synthesised]? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response),
              let content = envelope.choices.first?.message.content,
              let data = content.data(using: .utf8),
              let inner = try? JSONDecoder().decode(PatternsBody.self, from: data)
        else { return nil }
        return inner.patterns.compactMap { p in
            let h = p.headline.trimmingCharacters(in: .whitespacesAndNewlines)
            let s = p.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !h.isEmpty, !s.isEmpty else { return nil }
            return Synthesised(headline: h, summary: s)
        }
    }

    static func parseContradictions(response: Data) -> [Synthesised]? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response),
              let content = envelope.choices.first?.message.content,
              let data = content.data(using: .utf8),
              let inner = try? JSONDecoder().decode(ContradictionsBody.self, from: data)
        else { return nil }
        return inner.contradictions.compactMap { c in
            let h = c.headline.trimmingCharacters(in: .whitespacesAndNewlines)
            let s = c.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !h.isEmpty, !s.isEmpty else { return nil }
            return Synthesised(headline: h, summary: s)
        }
    }
}

private struct GraphContradictionRow: Decodable {
    let edge_id: UUID
    let left_label: String
    let right_label: String
    let rationale: String
    let memory_ids: [UUID]
}

// MARK: - Wire types

private struct OutboundBody: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let response_format: ResponseFormat
    let stream: Bool
    struct ResponseFormat: Encodable { let type: String }
    enum CodingKeys: String, CodingKey { case model, messages, temperature, response_format, stream }
}

private struct Envelope: Decodable {
    struct Choice: Decodable { let message: AssistantMessage }
    struct AssistantMessage: Decodable { let content: String? }
    let choices: [Choice]
}

private struct SynthesisBody: Decodable {
    let headline: String
    let summary: String
}

private struct PatternsBody: Decodable {
    struct Pattern: Decodable {
        let headline: String
        let summary: String
    }

    let patterns: [Pattern]
}

private struct ContradictionsBody: Decodable {
    struct Contradiction: Decodable {
        let headline: String
        let summary: String
    }

    let contradictions: [Contradiction]
}
