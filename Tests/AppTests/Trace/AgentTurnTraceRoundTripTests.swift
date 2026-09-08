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

    /// A trace names the model, the tools and the cost of a turn. Leaking one
    /// across tenants would disclose another user's activity, so the query is
    /// filtered on `tenant_id` and not merely on the message ids it was handed.
    @Test
    func `traces are scoped to their tenant`() async throws {
        try await withTestFluent(label: "lv.test.trace.isolation") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let owner = UUID()
            let other = UUID()
            try await Self.makeUser(owner, "trace-owner").save(on: fluent.db())
            try await Self.makeUser(other, "trace-other").save(on: fluent.db())

            let recorder = AgentTurnTraceRecorder(fluent: fluent, logger: Logger(label: "test.trace"))
            for tenant in [owner, other] {
                await recorder.record(.init(
                    tenantID: tenant, conversationMessageID: nil,
                    provider: .openai, model: "gpt-4o-mini",
                    toolNames: ["secret_tool"], toolCallCount: nil, failoverCount: 0,
                    tokensIn: 1, tokensOut: 1, estimatedCostUsdMicros: 1, latencyMs: 1,
                    credentialMode: .managed
                ))
            }

            let ownerRows = try await AgentTurnTrace.query(on: fluent.db())
                .filter(\.$tenantID == owner).all()
            #expect(ownerRows.count == 1)
            #expect(ownerRows.allSatisfy { $0.tenantID == owner })
        }
    }

    /// The DTO is what a client sees; it must not invent a count for a turn
    /// whose tools we never learned.
    @Test
    func `the DTO reports names and counts as recorded`() async throws {
        try await withTestFluent(label: "lv.test.trace.dto") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            try await Self.truncate(fluent)

            let tenantID = UUID()
            try await Self.makeUser(tenantID, "trace-dto").save(on: fluent.db())
            let recorder = AgentTurnTraceRecorder(fluent: fluent, logger: Logger(label: "test.trace"))
            // Streaming shape: a count, no names.
            await recorder.record(.init(
                tenantID: tenantID, conversationMessageID: nil,
                provider: .anthropic, model: "claude-sonnet-4-6",
                toolNames: nil, toolCallCount: 3, failoverCount: 1,
                tokensIn: 10, tokensOut: 20, estimatedCostUsdMicros: 30, latencyMs: 40,
                credentialMode: .byok
            ))

            let row = try #require(
                try await AgentTurnTrace.query(on: fluent.db()).filter(\.$tenantID == tenantID).first()
            )
            let dto = try #require(row.toDTO())
            #expect(dto.toolCallCount == 3)
            #expect(dto.toolNames.isEmpty, "the streaming path never learned the names")
            #expect(dto.failoverCount == 1)
            #expect(dto.credentialMode == .byok)
            #expect(dto.provider == .anthropic)
        }
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
                toolCallCount: nil,
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
                toolNames: ["one"], toolCallCount: nil, failoverCount: 0,
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
                provider: .openai, model: "m", toolNames: [], toolCallCount: nil, failoverCount: 0,
                tokensIn: 0, tokensOut: 0, estimatedCostUsdMicros: 0, latencyMs: 0,
                credentialMode: nil
            ))
            await recorder.record(.init(
                tenantID: tenantID, conversationMessageID: nil,
                provider: .openai, model: "m", toolNames: nil, toolCallCount: nil, failoverCount: 0,
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
