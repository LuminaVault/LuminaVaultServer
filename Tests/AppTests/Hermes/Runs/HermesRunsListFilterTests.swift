@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// `GET /v1/hermes/runs?conversationID=` — how a chat client recovers the run
/// backing a conversation after losing the stream that carried its id.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct HermesRunsListFilterTests {
    private static func withTenant(
        _ body: (Fluent, UUID) async throws -> Void
    ) async throws {
        try await withTestFluent(label: "test.hermes.runs.listfilter") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let user = User(
                email: "runfilter-\(suffix)@test.luminavault",
                username: "runfilter-\(suffix)",
                passwordHash: "stub"
            )
            try await user.save(on: fluent.db())
            try await DefaultAuthService.ensurePersonalVault(for: user, on: fluent.db())
            try await body(fluent, user.requireID())
        }
    }

    private static func makeStore(_ fluent: Fluent) -> HermesRunStore {
        HermesRunStore(
            fluent: fluent,
            eventBus: EventBus(logger: Logger(label: "test.runs.listfilter.bus")),
            logger: Logger(label: "test.runs.listfilter")
        )
    }

    /// `hermes_runs.conversation_id` is a real foreign key into
    /// `conversations` (M117), so a test cannot invent one.
    private static func makeConversation(_ fluent: Fluent, tenantID: UUID, title: String) async throws -> UUID {
        let convo = Conversation(tenantID: tenantID, title: title)
        try await convo.save(on: fluent.db())
        return try convo.requireID()
    }

    @discardableResult
    private static func makeRun(
        _ fluent: Fluent,
        tenantID: UUID,
        conversationID: UUID?,
        tag: String
    ) async throws -> HermesRun {
        let run = HermesRun(
            tenantID: tenantID,
            hermesRunID: "run_\(tag)_\(UUID().uuidString.prefix(6).lowercased())",
            prompt: tag,
            conversationID: conversationID
        )
        try await run.save(on: fluent.db())
        return run
    }

    @Test("Filtering by conversation returns only that conversation's runs")
    func filtersToOneConversation() async throws {
        try await Self.withTenant { fluent, tenantID in
            let store = Self.makeStore(fluent)
            let wanted = try await Self.makeConversation(fluent, tenantID: tenantID, title: "wanted")
            let other = try await Self.makeConversation(fluent, tenantID: tenantID, title: "other")

            let a = try await Self.makeRun(fluent, tenantID: tenantID, conversationID: wanted, tag: "a")
            let b = try await Self.makeRun(fluent, tenantID: tenantID, conversationID: wanted, tag: "b")
            _ = try await Self.makeRun(fluent, tenantID: tenantID, conversationID: other, tag: "c")
            _ = try await Self.makeRun(fluent, tenantID: tenantID, conversationID: nil, tag: "standalone")

            let filtered = try await store.list(tenantID: tenantID, limit: 50, conversationID: wanted)
            #expect(Set(filtered.compactMap(\.id)) == Set([a, b].compactMap(\.id)))
        }
    }

    /// Omitting the filter must keep the existing behaviour exactly — this is
    /// an added parameter on a live endpoint, not a change to it.
    @Test("Omitting the filter still returns every run for the tenant")
    func unfilteredIsUnchanged() async throws {
        try await Self.withTenant { fluent, tenantID in
            let store = Self.makeStore(fluent)
            let convo = try await Self.makeConversation(fluent, tenantID: tenantID, title: "a")
            _ = try await Self.makeRun(fluent, tenantID: tenantID, conversationID: convo, tag: "a")
            _ = try await Self.makeRun(fluent, tenantID: tenantID, conversationID: nil, tag: "b")

            let all = try await store.list(tenantID: tenantID, limit: 50)
            #expect(all.count == 2)
        }
    }

    @Test("A conversation with no runs returns empty rather than everything")
    func unknownConversationReturnsEmpty() async throws {
        try await Self.withTenant { fluent, tenantID in
            let store = Self.makeStore(fluent)
            let convo = try await Self.makeConversation(fluent, tenantID: tenantID, title: "a")
            _ = try await Self.makeRun(fluent, tenantID: tenantID, conversationID: convo, tag: "a")
            let empty = try await Self.makeConversation(fluent, tenantID: tenantID, title: "empty")

            let none = try await store.list(tenantID: tenantID, limit: 50, conversationID: empty)
            #expect(none.isEmpty)
        }
    }

    /// Runs with no conversation are agent runs started from the Agent Runs
    /// screen. They must never leak into a conversation's list.
    @Test("Standalone runs never match a conversation filter")
    func standaloneRunsAreExcluded() async throws {
        try await Self.withTenant { fluent, tenantID in
            let store = Self.makeStore(fluent)
            _ = try await Self.makeRun(fluent, tenantID: tenantID, conversationID: nil, tag: "standalone")
            let convo = try await Self.makeConversation(fluent, tenantID: tenantID, title: "unrelated")

            let filtered = try await store.list(tenantID: tenantID, limit: 50, conversationID: convo)
            #expect(filtered.isEmpty)
        }
    }
}
