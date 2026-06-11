@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import LuminaVaultShared
import Testing

/// HER-37 Slice B — persistence + prompt-construction tests for the
/// conversations subsystem. The HTTP-level tests follow the existing
/// `withTestFluent` + `registerMigrations` pattern so they exercise the
/// full migration stack (including M44/M45) against a real local
/// Postgres.
@Suite(.serialized)
struct ConversationTests {
    // MARK: - Unit: prompt construction (no DB)

    @Test
    func `buildPrompt replays history with system context prepended`() {
        let convID = UUID()
        let history = [
            ConversationMessage(conversationID: convID, role: .user, content: "ran 5k Monday"),
            ConversationMessage(conversationID: convID, role: .assistant, content: "Nice pace."),
            ConversationMessage(conversationID: convID, role: .user, content: "any contradictions?"),
        ]
        let hits = [
            MemorySearchResult(
                id: UUID(),
                tenantID: UUID(),
                content: "skipped run Tuesday",
                createdAt: nil,
                distance: 0.15
            ),
        ]
        let messages = ConversationController.buildPrompt(history: history, hits: hits)
        #expect(messages.count == 4)
        #expect(messages[0].role == "system")
        #expect(messages[0].content.contains("[1] skipped run Tuesday"))
        #expect(messages[1].role == "user")
        #expect(messages[1].content == "ran 5k Monday")
        #expect(messages[2].role == "assistant")
        #expect(messages[3].content == "any contradictions?")
    }

    @Test
    func `buildPrompt with no hits surfaces fallback context`() {
        let messages = ConversationController.buildPrompt(history: [], hits: [])
        #expect(messages.count == 1)
        #expect(messages[0].content.contains("no relevant memories"))
    }

    // MARK: - Integration: Postgres-backed persistence

    @Test
    func `Conversation save + retrieve round trips`() async throws {
        try await withTestFluent(label: "lv.test.conv.crud") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let tenantID = try await Self.makeTenant(on: fluent)
            let convo = Conversation(tenantID: tenantID, title: "Sleep patterns")
            try await convo.save(on: fluent.db())
            let id = try convo.requireID()

            let fetched = try #require(
                await Conversation.query(on: fluent.db(), tenantID: tenantID)
                    .filter(\.$id == id)
                    .first()
            )
            #expect(fetched.title == "Sleep patterns")
            #expect(fetched.tenantID == tenantID)
            #expect(fetched.createdAt != nil)
        }
    }

    @Test
    func `ConversationMessage persists role content and source memory ids`() async throws {
        try await withTestFluent(label: "lv.test.conv.msg") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let tenantID = try await Self.makeTenant(on: fluent)
            let convo = Conversation(tenantID: tenantID, title: "thread")
            try await convo.save(on: fluent.db())
            let convID = try convo.requireID()

            let memID = UUID()
            let msg = ConversationMessage(
                conversationID: convID,
                role: .assistant,
                content: "Based on [1] you ran 5k.",
                sourceMemoryIDs: [memID]
            )
            try await msg.save(on: fluent.db())

            let rows = try await ConversationMessage.query(on: fluent.db())
                .filter(\.$conversationID == convID)
                .all()
            #expect(rows.count == 1)
            #expect(rows[0].role == "assistant")
            #expect(rows[0].content == "Based on [1] you ran 5k.")
            #expect(rows[0].sourceMemoryIDs == [memID])
        }
    }

    @Test
    func `deleting a conversation cascades its messages`() async throws {
        try await withTestFluent(label: "lv.test.conv.cascade") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let tenantID = try await Self.makeTenant(on: fluent)
            let convo = Conversation(tenantID: tenantID, title: "scratch")
            try await convo.save(on: fluent.db())
            let convID = try convo.requireID()

            for role in [ConversationMessageRole.user, .assistant] {
                let m = ConversationMessage(conversationID: convID, role: role, content: "hi")
                try await m.save(on: fluent.db())
            }
            try await convo.delete(on: fluent.db())

            let surviving = try await ConversationMessage.query(on: fluent.db())
                .filter(\.$conversationID == convID)
                .count()
            #expect(surviving == 0)
        }
    }

    @Test
    func `list returns conversations ordered by updatedAt desc`() async throws {
        try await withTestFluent(label: "lv.test.conv.order") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let tenantID = try await Self.makeTenant(on: fluent)
            let older = Conversation(tenantID: tenantID, title: "older")
            try await older.save(on: fluent.db())
            // Force ordering by touching the newer row after the older one.
            try await Task.sleep(nanoseconds: 1_000_000)
            let newer = Conversation(tenantID: tenantID, title: "newer")
            try await newer.save(on: fluent.db())

            let rows = try await Conversation.query(on: fluent.db(), tenantID: tenantID)
                .sort(\.$updatedAt, .descending)
                .all()
            #expect(rows.count == 2)
            #expect(rows[0].title == "newer")
            #expect(rows[1].title == "older")
        }
    }

    @Test
    func `Conversation query is tenant scoped`() async throws {
        try await withTestFluent(label: "lv.test.conv.tenant") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let tenantA = try await Self.makeTenant(on: fluent)
            let tenantB = try await Self.makeTenant(on: fluent)
            try await Conversation(tenantID: tenantA, title: "A").save(on: fluent.db())
            try await Conversation(tenantID: tenantB, title: "B").save(on: fluent.db())

            let rowsA = try await Conversation.query(on: fluent.db(), tenantID: tenantA).all()
            #expect(rowsA.count == 1)
            #expect(rowsA[0].title == "A")
        }
    }

    // MARK: - Fixtures

    private static func makeTenant(on fluent: Fluent) async throws -> UUID {
        let id = UUID()
        let user = User(
            id: id,
            email: "conv-\(UUID().uuidString.prefix(8).lowercased())@test.luminavault",
            username: "conv-\(UUID().uuidString.prefix(6).lowercased())",
            passwordHash: "stub"
        )
        try await user.save(on: fluent.db())
        return id
    }
}
