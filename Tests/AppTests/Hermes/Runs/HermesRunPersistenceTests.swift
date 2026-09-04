@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import LuminaVaultShared
import SQLKit
import Testing

/// Schema + round-trip guarantees for the two Phase 1 tables. The payload
/// cases are regression tests: a bare `AnyJSONValue` Fluent field reads a
/// `jsonb` column back as `.string("{…}")`, because its decoder tries
/// `String` first and the Postgres single-value container obliges — which
/// would double-encode every event on the wire.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct HermesRunPersistenceTests {
    private struct IndexRow: Codable {
        let indexname: String
    }

    private struct ColumnRow: Codable {
        let column_name: String
        let data_type: String
    }

    private static func withMigratedRun(
        _ body: (Fluent, HermesRun) async throws -> Void
    ) async throws {
        try await withTestFluent(label: "test.hermes.runs.persistence") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let user = User(
                email: "runrow-\(suffix)@test.luminavault",
                username: "runrow-\(suffix)",
                passwordHash: "stub"
            )
            try await user.save(on: fluent.db())
            let run = try HermesRun(
                tenantID: user.requireID(),
                hermesRunID: "run_\(suffix)",
                prompt: "persist me"
            )
            try await run.save(on: fluent.db())
            try await body(fluent, run)
        }
    }

    // MARK: - Migrations

    @Test
    func `M117 and M118 create the tables, indexes and category columns`() async throws {
        try await withTestFluent(label: "test.hermes.runs.migrations") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            guard let sql = fluent.db() as? any SQLDatabase else {
                Issue.record("SQL driver required")
                return
            }

            let runIndexes = try await sql.raw("""
            SELECT indexname FROM pg_indexes WHERE tablename = 'hermes_runs'
            """).all(decoding: IndexRow.self).map(\.indexname)
            #expect(runIndexes.contains("idx_hermes_runs_tenant_started_at"))
            #expect(runIndexes.contains("idx_hermes_runs_active"))
            #expect(runIndexes.contains("uq_hermes_runs_tenant_hermes_run_id"))

            let eventIndexes = try await sql.raw("""
            SELECT indexname FROM pg_indexes WHERE tablename = 'hermes_run_events'
            """).all(decoding: IndexRow.self).map(\.indexname)
            #expect(eventIndexes.contains("uq_hermes_run_events_run_seq"))

            let payload = try await sql.raw("""
            SELECT column_name, data_type FROM information_schema.columns
            WHERE table_name = 'hermes_run_events' AND column_name = 'payload'
            """).all(decoding: ColumnRow.self)
            #expect(payload.first?.data_type == "jsonb")

            // M119 — the two new push-preference columns default to allowed.
            let prefColumns = try await sql.raw("""
            SELECT column_name, data_type FROM information_schema.columns
            WHERE table_name = 'apns_category_prefs'
              AND column_name IN ('approval_enabled', 'run_completed_enabled')
            """).all(decoding: ColumnRow.self).map(\.column_name)
            #expect(Set(prefColumns) == ["approval_enabled", "run_completed_enabled"])
        }
    }

    @Test
    func `M119 defaults both new push categories to enabled`() async throws {
        try await withTestFluent(label: "test.hermes.runs.prefs") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let user = User(
                email: "prefs-\(suffix)@test.luminavault",
                username: "prefs-\(suffix)",
                passwordHash: "stub"
            )
            try await user.save(on: fluent.db())
            let tenantID = try user.requireID()
            try await ApnsCategoryPrefs(tenantID: tenantID).save(on: fluent.db())

            let stored = try #require(try await ApnsCategoryPrefs.find(tenantID, on: fluent.db()))
            #expect(stored.approvalEnabled)
            #expect(stored.runCompletedEnabled)
        }
    }

    // MARK: - Payload round-trip

    @Test
    func `a nested event payload round-trips through jsonb as an object`() async throws {
        try await Self.withMigratedRun { fluent, run in
            let payload = AnyJSONValue.object([
                "event": .string("approval.request"),
                "command": .string("rm -rf ***"),
                "choices": .array([.string("once"), .string("deny")]),
                "meta": .object(["risk": .number(3), "blocking": .bool(true)]),
                "nothing": .null,
            ])
            try await HermesRunEventRow(
                runID: run.requireID(),
                seq: 1,
                event: "approval.request",
                payload: payload
            ).save(on: fluent.db())

            let read = try #require(
                try await HermesRunEventRow.query(on: fluent.db())
                    .filter(\.$runID == run.requireID())
                    .first()
            )
            let dto = read.toDTO()
            let object = try #require(dto.payload.objectValue)
            #expect(object["command"]?.stringValue == "rm -rf ***")
            #expect(object["choices"]?.arrayValue?.compactMap(\.stringValue) == ["once", "deny"])
            #expect(object["meta"]?.objectValue?["risk"]?.doubleValue == 3)
            #expect(object["meta"]?.objectValue?["blocking"]?.boolValue == true)
            #expect(object["nothing"] == .null)
        }
    }

    @Test
    func `a scalar payload is wrapped rather than lost`() async throws {
        try await Self.withMigratedRun { fluent, run in
            try await HermesRunEventRow(
                runID: run.requireID(),
                seq: 1,
                event: "ping",
                payload: .string("pong")
            ).save(on: fluent.db())

            let read = try #require(
                try await HermesRunEventRow.query(on: fluent.db())
                    .filter(\.$runID == run.requireID())
                    .first()
            )
            #expect(read.payload[HermesRunEventRow.scalarPayloadKey]?.stringValue == "pong")
        }
    }

    @Test
    func `a pending approval round-trips through jsonb with its extras`() async throws {
        try await Self.withMigratedRun { fluent, run in
            run.pendingApproval = HermesRunPendingApprovalDTO(
                command: "curl ***",
                choices: [.once, .deny],
                requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
                extra: ["tool": .string("shell"), "attempts": .number(2)]
            )
            run.runStatus = .waitingForApproval
            try await run.save(on: fluent.db())

            let read = try #require(try await HermesRun.find(run.requireID(), on: fluent.db()))
            let pending = try #require(read.pendingApproval)
            #expect(pending.command == "curl ***")
            #expect(pending.choices == [.once, .deny])
            #expect(pending.requestedAt == Date(timeIntervalSince1970: 1_700_000_000))
            #expect(pending.extra?["tool"]?.stringValue == "shell")
            #expect(pending.extra?["attempts"]?.doubleValue == 2)
            #expect(read.runStatus == .waitingForApproval)
        }
    }

    @Test
    func `an unknown status string reads as lost rather than as an active run`() async throws {
        try await Self.withMigratedRun { _, run in
            run.status = "something-else"
            #expect(run.runStatus == .lost)
            #expect(run.runStatus.isTerminal)
        }
    }

    @Test
    func `the same seq cannot be persisted twice for one run`() async throws {
        try await Self.withMigratedRun { fluent, run in
            let runID = try run.requireID()
            try await HermesRunEventRow(runID: runID, seq: 1, event: "run.started", payload: .object([:]))
                .save(on: fluent.db())
            await #expect(throws: (any Error).self) {
                try await HermesRunEventRow(runID: runID, seq: 1, event: "run.started", payload: .object([:]))
                    .save(on: fluent.db())
            }
        }
    }

    @Test
    func `deleting a run cascades to its events`() async throws {
        try await Self.withMigratedRun { fluent, run in
            let runID = try run.requireID()
            try await HermesRunEventRow(runID: runID, seq: 1, event: "run.started", payload: .object([:]))
                .save(on: fluent.db())
            try await run.delete(on: fluent.db())
            let remaining = try await HermesRunEventRow.query(on: fluent.db())
                .filter(\.$runID == runID)
                .count()
            #expect(remaining == 0)
        }
    }
}
