import FluentKit
import FluentPostgresDriver
import Foundation
import HummingbirdFluent
import Logging
import SQLKit
import Testing

@testable import App

/// HER-146 unit tests for `HealthCorrelationService`.
/// Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct HealthCorrelationServiceTests {

    // MARK: - Stub transport

    /// Records each chat call + returns a configurable canned response.
    actor StubHermesTransport: HermesChatTransport {
        var calls: [(payload: Data, profile: String)] = []
        var cannedAssistantContent: String

        init(cannedAssistantContent: String = "Stub synthesis.\n- When step count dropped, the user's notes mentioned fatigue.") {
            self.cannedAssistantContent = cannedAssistantContent
        }

        func setCanned(_ s: String) { self.cannedAssistantContent = s }

        func chatCompletions(payload: Data, profileUsername: String) async throws -> Data {
            calls.append((payload, profileUsername))
            let body: [String: Any] = [
                "id": "stub-\(UUID().uuidString)",
                "model": "stub-model",
                "choices": [
                    ["index": 0,
                     "message": ["role": "assistant", "content": cannedAssistantContent],
                     "finish_reason": "stop"]
                ]
            ]
            return try JSONSerialization.data(withJSONObject: body)
        }
    }

    // MARK: - Harness

    fileprivate struct Harness: Sendable {
        let service: HealthCorrelationService
        let transport: StubHermesTransport
        let fluent: Fluent
        let memoryRepo: MemoryRepository
    }

    private static func withHarness<T: Sendable>(
        _ body: @Sendable (Harness) async throws -> T
    ) async throws -> T {
        let logger = Logger(label: "test.health-correlate")
        let fluent = Fluent(logger: logger)
        fluent.databases.use(
            .postgres(configuration: TestPostgres.configuration()),
            as: .psql
        )
        let transport = StubHermesTransport()
        let memoryRepo = MemoryRepository(fluent: fluent)
        let service = HealthCorrelationService(
            transport: transport,
            fluent: fluent,
            embeddings: DeterministicEmbeddingService(),
            memories: memoryRepo,
            defaultModel: "stub",
            logger: logger
        )
        let harness = Harness(service: service, transport: transport, fluent: fluent, memoryRepo: memoryRepo)
        do {
            let result = try await body(harness)
            try await fluent.shutdown()
            return result
        } catch {
            try? await fluent.shutdown()
            throw error
        }
    }

    /// Seeds a fresh user row + returns the persisted `User` for use in `service.correlate(user:)`.
    private static func makeUser(fluent: Fluent) async throws -> User {
        let username = "hc-\(UUID().uuidString.prefix(8).lowercased())"
        let user = User(
            email: "\(username)@test.luminavault",
            username: username,
            passwordHash: "x"
        )
        try await user.save(on: fluent.db())
        return user
    }

    /// Inserts N HealthEvent rows spread across the requested date range.
    private static func seedHealthEvents(
        fluent: Fluent,
        tenantID: UUID,
        count: Int,
        from start: Date,
        to end: Date
    ) async throws {
        let stepSeconds = max(1, Int(end.timeIntervalSince(start)) / max(1, count))
        for i in 0..<count {
            let when = start.addingTimeInterval(Double(i * stepSeconds))
            let row = HealthEvent(
                tenantID: tenantID,
                eventType: i.isMultiple(of: 2) ? "steps" : "sleep_hours",
                valueNumeric: Double(1000 + i * 37),
                unit: i.isMultiple(of: 2) ? "count" : "hours",
                recordedAt: when,
                source: "test"
            )
            try await row.save(on: fluent.db())
        }
    }

    private static func seedMemory(fluent: Fluent, tenantID: UUID, content: String) async throws {
        let m = Memory(tenantID: tenantID, content: content)
        try await m.save(on: fluent.db())
    }

    // MARK: - Tests

    @Test
    func skipsWhenInsufficientHistory() async throws {
        try await Self.withHarness { h in
            let user = try await Self.makeUser(fluent: h.fluent)
            // Only 5 days of history — well below the 30-day floor.
            let now = Date()
            try await Self.seedHealthEvents(
                fluent: h.fluent,
                tenantID: try user.requireID(),
                count: 5,
                from: now.addingTimeInterval(-5 * 86_400),
                to: now
            )
            let outcome = try await h.service.correlate(user: user, now: now)
            #expect(outcome == .skippedInsufficientHistory)
            let callCount = await h.transport.calls.count
            #expect(callCount == 0, "must not call Hermes when history is short")
        }
    }

    @Test
    func skipsWhenNoEventsInWindow() async throws {
        try await Self.withHarness { h in
            let user = try await Self.makeUser(fluent: h.fluent)
            let now = Date()
            // 30+ days of OLD history but nothing in the last 7d.
            try await Self.seedHealthEvents(
                fluent: h.fluent,
                tenantID: try user.requireID(),
                count: 30,
                from: now.addingTimeInterval(-60 * 86_400),
                to: now.addingTimeInterval(-10 * 86_400)   // ends >7d ago
            )
            let outcome = try await h.service.correlate(user: user, now: now)
            #expect(outcome == .skippedNoRecentEvents)
        }
    }

    @Test
    func savesOnHappyPath() async throws {
        try await Self.withHarness { h in
            let user = try await Self.makeUser(fluent: h.fluent)
            let now = Date()
            try await Self.seedHealthEvents(
                fluent: h.fluent,
                tenantID: try user.requireID(),
                count: 40,
                from: now.addingTimeInterval(-35 * 86_400),
                to: now.addingTimeInterval(-60)
            )
            try await Self.seedMemory(fluent: h.fluent, tenantID: try user.requireID(), content: "felt tired today")

            let outcome = try await h.service.correlate(user: user, now: now)
            guard case let .saved(memoryID) = outcome else {
                Issue.record("expected .saved, got \(outcome)")
                return
            }
            // Memory row was persisted with the right tags + content.
            let memory = try #require(try await Memory.find(memoryID, on: h.fluent.db()))
            #expect(memory.tags == ["correlation", "weekly"])
            #expect(!memory.content.isEmpty)

            // Hermes was called exactly once.
            let callCount = await h.transport.calls.count
            #expect(callCount == 1)
        }
    }

    @Test
    func secondRunSameWeekIsSkipped() async throws {
        try await Self.withHarness { h in
            let user = try await Self.makeUser(fluent: h.fluent)
            let now = Date()
            try await Self.seedHealthEvents(
                fluent: h.fluent,
                tenantID: try user.requireID(),
                count: 40,
                from: now.addingTimeInterval(-35 * 86_400),
                to: now.addingTimeInterval(-60)
            )
            // First run saves.
            let first = try await h.service.correlate(user: user, now: now)
            guard case .saved = first else {
                Issue.record("setup: expected first run to save, got \(first)")
                return
            }
            // Second run within the same 7-day window is a no-op.
            let second = try await h.service.correlate(user: user, now: now)
            #expect(second == .skippedAlreadyRanThisWeek)
            let callCount = await h.transport.calls.count
            #expect(callCount == 1, "idempotent — Hermes must be hit at most once per week")
        }
    }

    @Test
    func skipsWhenSynthesisEmpty() async throws {
        try await Self.withHarness { h in
            await h.transport.setCanned("   \n  ")   // whitespace only → trimmed empty
            let user = try await Self.makeUser(fluent: h.fluent)
            let now = Date()
            try await Self.seedHealthEvents(
                fluent: h.fluent,
                tenantID: try user.requireID(),
                count: 40,
                from: now.addingTimeInterval(-35 * 86_400),
                to: now.addingTimeInterval(-60)
            )
            let outcome = try await h.service.correlate(user: user, now: now)
            #expect(outcome == .skippedNoSynthesis)
        }
    }

    @Test
    func promptIncludesHealthAndMemorySections() async throws {
        let now = Date()
        let tenantID = UUID()
        let event = HealthEvent(
            tenantID: tenantID,
            eventType: "steps",
            valueNumeric: 8420,
            unit: "count",
            recordedAt: now.addingTimeInterval(-3600)
        )
        let memory = Memory(
            tenantID: tenantID,
            content: "Slept poorly. Skipped the morning run."
        )
        memory.createdAt = now.addingTimeInterval(-3600)
        let prompt = HealthCorrelationService.buildUserPrompt(events: [event], memories: [memory], now: now)
        #expect(prompt.contains("## Health events"))
        #expect(prompt.contains("steps"))
        #expect(prompt.contains("8420"))
        #expect(prompt.contains("## Memories"))
        #expect(prompt.contains("Slept poorly"))
    }
}
