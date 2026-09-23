@testable import App
import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import Testing

/// The loop guard, against Postgres with scripted agents.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct AgentRoomOrchestratorTests {
    /// Replies from a script keyed by handle; records who was asked.
    final class ScriptedSpeaker: AgentRoomSpeaker, @unchecked Sendable {
        // `@unchecked`: all state lives behind `lock`; the class is a test double.
        private let lock = NSLock()
        private var askedHandles: [String] = []
        private var lastMessages: [String: String] = [:]
        let script: @Sendable (String) throws -> String
        let tokens: Int?
        let onAsk: (@Sendable (AgentRoom) async throws -> Void)?

        init(tokens: Int? = 10, onAsk: (@Sendable (AgentRoom) async throws -> Void)? = nil, script: @escaping @Sendable (String) throws -> String) {
            self.script = script
            self.tokens = tokens
            self.onAsk = onAsk
        }

        var asked: [String] {
            lock.withLock { askedHandles }
        }

        func lastMessage(to handle: String) -> String? {
            lock.withLock { lastMessages[handle] }
        }

        func reply(userID _: UUID, room: AgentRoom, member: AgentRoomMember, systemMessage _: String, message: String) async throws -> (text: String, tokens: Int?) {
            lock.withLock {
                askedHandles.append(member.handle)
                lastMessages[member.handle] = message
            }
            try await onAsk?(room)
            return try (script(member.handle), tokens)
        }
    }

    struct Boom: Error {}

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [AgentRoomStreamEvent] = []
        func add(_ event: AgentRoomStreamEvent) {
            lock.withLock { items.append(event) }
        }

        var all: [AgentRoomStreamEvent] {
            lock.withLock { items }
        }
    }

    private static func makeRoom(
        on fluent: Fluent,
        budget: Int = 200_000,
        members: [(String, AgentRoomRespondMode)]
    ) async throws -> AgentRoom {
        let room = AgentRoom()
        room.tenantID = UUID()
        room.title = "Planning"
        room.tokenBudget = budget
        room.spentTokens = 0
        try await room.save(on: fluent.db())
        for (handle, mode) in members {
            let member = AgentRoomMember()
            member.roomID = try room.requireID()
            member.instanceID = "central"
            member.profile = handle
            member.handle = handle
            member.displayName = handle.capitalized
            member.respondMode = mode
            try await member.save(on: fluent.db())
            // Distinct created_at so member order is stable.
            try await Task.sleep(for: .milliseconds(5))
        }
        return room
    }

    private static func orchestrator(_ fluent: Fluent, _ speaker: some AgentRoomSpeaker) -> AgentRoomOrchestrator {
        AgentRoomOrchestrator(fluent: fluent, speaker: speaker, registry: AgentRoomRunRegistry(), logger: Logger(label: "test.rooms"))
    }

    private static func messages(_ room: AgentRoom, on fluent: Fluent) async throws -> [AgentRoomMessage] {
        try await AgentRoomMessage.query(on: fluent.db()).filter(\.$roomID == room.requireID()).sort(\.$createdAt).all()
    }

    @Test
    func `two agents handing over forever stop at the turn cap`() async throws {
        try await withTestFluent(label: "lv.test.rooms.cap") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let room = try await Self.makeRoom(on: fluent, members: [("alpha", .mention), ("beta", .mention)])
            let speaker = ScriptedSpeaker { handle in handle == "alpha" ? "over to @beta" : "back to @alpha" }
            let events = Collected()

            let reason = try await Self.orchestrator(fluent, speaker).post(userID: room.tenantID, room: room, body: "@alpha start") {
                events.add($0)
            }

            #expect(reason == .turnCap)
            #expect(speaker.asked == ["alpha", "beta", "alpha", "beta", "alpha", "beta"])
            let rows = try await Self.messages(room, on: fluent)
            #expect(rows.first?.authorKind == .human)
            #expect(rows.filter { $0.authorKind == .agent }.count == AgentRoomTurnPolicy.maxAgentTurns)
            #expect(rows.last?.authorKind == .system)
            #expect(rows.last?.body.contains("Paused after 6") == true)
            #expect(events.all.filter { $0.kind == .thinking }.count == 6)
        }
    }

    @Test
    func `nobody answers twice in a row and an unaddressed reply ends the chain`() async throws {
        try await withTestFluent(label: "lv.test.rooms.idle") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let room = try await Self.makeRoom(on: fluent, members: [("alpha", .everyHumanMessage), ("beta", .mention)])
            // alpha names itself and beta; beta names nobody.
            let speaker = ScriptedSpeaker { handle in handle == "alpha" ? "I, @alpha, ask @beta" : "done" }

            let reason = try await Self.orchestrator(fluent, speaker).post(userID: room.tenantID, room: room, body: "hello") { _ in }

            #expect(reason == .idle)
            #expect(speaker.asked == ["alpha", "beta"])
            // beta's first turn sees the user's message and alpha's reply.
            let seen = try #require(speaker.lastMessage(to: "beta"))
            #expect(seen.contains("User: hello"))
            #expect(seen.contains("@alpha: I, @alpha, ask @beta"))
        }
    }

    @Test
    func `a spent budget stops the chain before the next call`() async throws {
        try await withTestFluent(label: "lv.test.rooms.budget") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let room = try await Self.makeRoom(on: fluent, budget: 100, members: [("alpha", .mention), ("beta", .mention)])
            let speaker = ScriptedSpeaker(tokens: 150) { handle in handle == "alpha" ? "@beta" : "@alpha" }

            let reason = try await Self.orchestrator(fluent, speaker).post(userID: room.tenantID, room: room, body: "@alpha go") { _ in }

            #expect(reason == .budget)
            #expect(speaker.asked == ["alpha"])
            let stored = try #require(try await AgentRoom.find(room.requireID(), on: fluent.db()))
            #expect(stored.spentTokens == 150)
        }
    }

    @Test
    func `stop ends the chain after the turn in flight`() async throws {
        try await withTestFluent(label: "lv.test.rooms.stop") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let room = try await Self.makeRoom(on: fluent, members: [("alpha", .mention), ("beta", .mention)])
            let speaker = ScriptedSpeaker(onAsk: { asked in
                // The user presses Stop while the first agent is thinking.
                guard let row = try await AgentRoom.find(asked.requireID(), on: fluent.db()) else { return }
                row.stopRequestedAt = Date()
                try await row.save(on: fluent.db())
            }) { handle in handle == "alpha" ? "@beta" : "@alpha" }

            let reason = try await Self.orchestrator(fluent, speaker).post(userID: room.tenantID, room: room, body: "@alpha go") { _ in }

            #expect(reason == .stopped)
            #expect(speaker.asked == ["alpha"])
            let rows = try await Self.messages(room, on: fluent)
            #expect(rows.last?.body == "Stopped.")
        }
    }

    @Test
    func `a failing agent is reported and the others still answer`() async throws {
        try await withTestFluent(label: "lv.test.rooms.fail") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let room = try await Self.makeRoom(on: fluent, members: [("alpha", .mention), ("beta", .mention)])
            let speaker = ScriptedSpeaker { handle in
                if handle == "alpha" {
                    throw Boom()
                }
                return "beta here"
            }

            let reason = try await Self.orchestrator(fluent, speaker).post(userID: room.tenantID, room: room, body: "@alpha and @beta") { _ in }

            #expect(reason == .idle)
            #expect(speaker.asked == ["alpha", "beta"])
            let rows = try await Self.messages(room, on: fluent)
            #expect(rows.contains { $0.authorKind == .system && $0.body.hasPrefix("@alpha could not answer") })
            #expect(rows.last?.body == "beta here")
        }
    }

    @Test
    func `a second chain in the same room is refused while one runs`() async throws {
        try await withTestFluent(label: "lv.test.rooms.busy") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()
            let room = try await Self.makeRoom(on: fluent, members: [("alpha", .mention)])
            let registry = AgentRoomRunRegistry()
            _ = try await registry.begin(room.requireID())
            let orchestrator = AgentRoomOrchestrator(
                fluent: fluent, speaker: ScriptedSpeaker { _ in "hi" }, registry: registry, logger: Logger(label: "test")
            )
            await #expect(throws: AgentRoomOrchestrator.RunError.alreadyRunning) {
                try await orchestrator.post(userID: room.tenantID, room: room, body: "@alpha") { _ in }
            }
            await #expect(throws: AgentRoomOrchestrator.RunError.emptyMessage) {
                try await orchestrator.post(userID: room.tenantID, room: room, body: "   ") { _ in }
            }
        }
    }
}
