@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit
import Testing

/// Writes a trace and reads back its *shape*.
///
/// This suite exists because of a bug that has already been hit twice in this
/// codebase, on 2026-09-04, in two different places (`HermesRunEventRow.payload`
/// and `hermes_mirrored_jobs.raw`): PostgresNIO hands a `jsonb` column to the
/// decoder as the column's raw JSON *text*, so a single-value-container type
/// reads back as a string of JSON rather than the value that was written, and
/// a load-then-save wraps it again — corrupting it a little more each time.
///
/// It fails silently. The write succeeds, the type checks out, and only a test
/// that asserts the shape of the value read back will catch it. Hence
/// `AgentToolCalls` being a keyed struct rather than a bare `[String]`, and
/// hence this test.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct AgentTurnTraceRoundTripTests {
    private static func makeUser(_ id: UUID, _ slug: String) -> User {
        User(
            id: id,
            email: "\(slug)@test.luminavault",
            username: slug,
            passwordHash: "stub-hash-\(slug)"
        )
    }

    private static func truncate(_ fluent: Fluent) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else { return }
        try await sql.raw("DELETE FROM agent_turn_traces").run()
        try await sql.raw("DELETE FROM users WHERE username LIKE 'trace-%'").run()
    }

    /// The assertion that matters: tool names come back as names, not as a
    /// JSON string that happens to contain them.
    @Test
    func `tool names survive the jsonb round trip as a list`() async throws {
        try await withTestFluent(label: "lv.test.trace.roundtrip") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let tenantID = UUID()
            try await Self.makeUser(tenantID, "trace-roundtrip").save(on: fluent.db())

            let recorder = AgentTurnTraceRecorder(fluent: fluent, logger: Logger(label: "test.trace"))
            await recorder.record(.init(
                tenantID: tenantID,
                conversationMessageID: nil,
                provider: .openai,
                model: "gpt-4o-mini",
                toolNames: ["search_memory", "read_vault_file"],
                failoverCount: 2,
                tokensIn: 1200,
                tokensOut: 340,
                estimatedCostUsdMicros: 384,
                latencyMs: 812,
                credentialMode: .managed
            ))

            let row = try #require(
                try await AgentTurnTrace.query(on: fluent.db())
                    .filter(\.$tenantID == tenantID)
                    .first()
            )
            // The shape, not merely the presence.
            #expect(row.toolCalls?.names == ["search_memory", "read_vault_file"])
            #expect(row.provider == "openai")
            #expect(row.model == "gpt-4o-mini")
            #expect(row.failoverCount == 2)
            #expect(row.tokensIn == 1200)
            #expect(row.tokensOut == 340)
            #expect(row.estimatedCostUsdMicros == 384)
            #expect(row.credentialMode == "managed")
        }
    }

    /// Load-then-save is where the double-encoding bug compounded. One extra
    /// cycle must not change the value.
    @Test
    func `a load and re-save does not re-encode the tool list`() async throws {
        try await withTestFluent(label: "lv.test.trace.resave") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let tenantID = UUID()
            try await Self.makeUser(tenantID, "trace-resave").save(on: fluent.db())

            let recorder = AgentTurnTraceRecorder(fluent: fluent, logger: Logger(label: "test.trace"))
            await recorder.record(.init(
                tenantID: tenantID, conversationMessageID: nil,
                provider: .anthropic, model: "claude-3-5-haiku-20241022",
                toolNames: ["one"], failoverCount: 0,
                tokensIn: 1, tokensOut: 1, estimatedCostUsdMicros: 1, latencyMs: 1,
                credentialMode: .byok
            ))

            let first = try #require(
                try await AgentTurnTrace.query(on: fluent.db()).filter(\.$tenantID == tenantID).first()
            )
            try await first.save(on: fluent.db())

            let second = try #require(
                try await AgentTurnTrace.query(on: fluent.db()).filter(\.$tenantID == tenantID).first()
            )
            #expect(second.toolCalls?.names == ["one"], "re-saving must not wrap the value again")
        }
    }

    /// Empty and nil are different answers: "called nothing" versus "we could
    /// not read the response". The trace surface renders them differently.
    @Test
    func `an empty tool list is distinct from an absent one`() async throws {
        try await withTestFluent(label: "lv.test.trace.empty") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let tenantID = UUID()
            try await Self.makeUser(tenantID, "trace-empty").save(on: fluent.db())
            let recorder = AgentTurnTraceRecorder(fluent: fluent, logger: Logger(label: "test.trace"))

            await recorder.record(.init(
                tenantID: tenantID, conversationMessageID: nil,
                provider: .openai, model: "m", toolNames: [], failoverCount: 0,
                tokensIn: 0, tokensOut: 0, estimatedCostUsdMicros: 0, latencyMs: 0,
                credentialMode: nil
            ))
            await recorder.record(.init(
                tenantID: tenantID, conversationMessageID: nil,
                provider: .openai, model: "m", toolNames: nil, failoverCount: 0,
                tokensIn: 0, tokensOut: 0, estimatedCostUsdMicros: 0, latencyMs: 0,
                credentialMode: nil
            ))

            let rows = try await AgentTurnTrace.query(on: fluent.db())
                .filter(\.$tenantID == tenantID).all()
            #expect(rows.count == 2)
            #expect(rows.contains { $0.toolCalls?.names == [] })
            #expect(rows.contains { $0.toolCalls == nil })
        }
    }
}
