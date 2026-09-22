@testable import App
import Foundation
import Hummingbird
import Testing

/// Who speaks next in an agent room.
struct AgentRoomTurnPolicyTests {
    private static let research = UUID()
    private static let ops = UUID()
    private static let opsbot = UUID()
    private static let members = [
        AgentRoomTurnPolicy.Member(id: research, handle: "research", respondMode: .everyHumanMessage),
        AgentRoomTurnPolicy.Member(id: ops, handle: "ops", respondMode: .mention),
        AgentRoomTurnPolicy.Member(id: opsbot, handle: "opsbot", respondMode: .mention),
    ]

    @Test
    func `mentions come back in the order they were written`() {
        let ids = AgentRoomTurnPolicy.mentions(in: "@ops look at this, then @research", members: Self.members)
        #expect(ids == [Self.ops, Self.research])
    }

    @Test
    func `a handle does not match inside a longer one`() {
        #expect(AgentRoomTurnPolicy.mentions(in: "ask @opsbot", members: Self.members) == [Self.opsbot])
        #expect(AgentRoomTurnPolicy.mentions(in: "ask @opsbot and @ops.", members: Self.members) == [Self.opsbot, Self.ops])
        #expect(AgentRoomTurnPolicy.mentions(in: "email ops@example.com", members: Self.members).isEmpty)
    }

    @Test
    func `an unaddressed message goes to members set to answer everything`() {
        #expect(AgentRoomTurnPolicy.firstResponders(to: "morning all", members: Self.members) == [Self.research])
        // Naming someone overrides the standing responders.
        #expect(AgentRoomTurnPolicy.firstResponders(to: "@ops only you", members: Self.members) == [Self.ops])
    }

    @Test
    func `a reply never queues its own speaker or a member twice`() {
        var queue = [Self.ops]
        AgentRoomTurnPolicy.enqueueHandovers(
            reply: "@research here, over to @ops and @opsbot, @research again",
            speaker: Self.research,
            members: Self.members,
            queue: &queue,
        )
        #expect(queue == [Self.ops, Self.opsbot])
    }

    @Test
    func `handles are derived and validated`() {
        #expect(AgentRoomTurnPolicy.handle(from: "Mac MCP") == "mac-mcp")
        #expect(AgentRoomTurnPolicy.handle(from: "  Stocks & News!! ") == "stocks-news")
        #expect(AgentRoomTurnPolicy.handle(from: "✨") == "agent")
        #expect(AgentRoomTurnPolicy.isValidHandle("mac-mcp"))
        #expect(!AgentRoomTurnPolicy.isValidHandle("Mac"))
        #expect(!AgentRoomTurnPolicy.isValidHandle("-ops"))
        #expect(!AgentRoomTurnPolicy.isValidHandle(""))
        #expect(!AgentRoomTurnPolicy.isValidHandle(String(repeating: "a", count: 32)))
    }

    @Test
    func `members must be ones the user can seat, with distinct handles`() throws {
        let available = [
            AgentRoomCandidateDTO(instanceID: "central", profile: "default", displayName: "Lumina", suggestedHandle: "default"),
            AgentRoomCandidateDTO(instanceID: "central", profile: "stocks", displayName: "Stocks", suggestedHandle: "stocks"),
            AgentRoomCandidateDTO(instanceID: "byo", profile: nil, displayName: "Hermes · mac-mcp", suggestedHandle: "mac-mcp"),
        ]
        let seated = try AgentRoomsController.resolveMembers([
            .init(instanceID: "central", profile: "stocks", handle: nil, displayName: nil, respondMode: .everyHumanMessage),
            .init(instanceID: "byo", profile: nil, handle: "vps", displayName: "My VPS", respondMode: nil),
        ], available: available)
        #expect(seated.map(\.handle) == ["stocks", "vps"])
        #expect(seated.map(\.displayName) == ["Stocks", "My VPS"])
        #expect(seated.map(\.respondMode) == [.everyHumanMessage, .mention])

        #expect(throws: HTTPError.self) {
            try AgentRoomsController.resolveMembers(
                [.init(instanceID: "central", profile: "someone-elses", handle: nil, displayName: nil, respondMode: nil)],
                available: available,
            )
        }
        #expect(throws: HTTPError.self) {
            try AgentRoomsController.resolveMembers([
                .init(instanceID: "central", profile: "default", handle: "x", displayName: nil, respondMode: nil),
                .init(instanceID: "central", profile: "stocks", handle: "x", displayName: nil, respondMode: nil),
            ], available: available)
        }
        #expect(throws: HTTPError.self) {
            try AgentRoomsController.resolveMembers([
                .init(instanceID: "byo", profile: nil, handle: "a", displayName: nil, respondMode: nil),
                .init(instanceID: "byo", profile: nil, handle: "b", displayName: nil, respondMode: nil),
            ], available: available)
        }
        #expect(throws: HTTPError.self) {
            try AgentRoomsController.resolveMembers(
                [.init(instanceID: "central", profile: "default", handle: "Bad Handle", displayName: nil, respondMode: nil)],
                available: available,
            )
        }
    }
}
