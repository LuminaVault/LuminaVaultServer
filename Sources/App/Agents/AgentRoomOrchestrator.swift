import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared

/// Who speaks next in a room, and when a chain of agent turns must end.
/// Pure, so the loop guard is testable without agents or a database.
enum AgentRoomTurnPolicy {
    /// Agent replies allowed per message the user posts.
    static let maxAgentTurns = 6
    /// Messages a member sees on its first turn in a room.
    static let firstTurnWindow = 20

    struct Member: Equatable, Sendable {
        let id: UUID
        let handle: String
        let respondMode: AgentRoomRespondMode
    }

    /// Members named as `@handle` in `text`, in order of first mention.
    static func mentions(in text: String, members: [Member]) -> [UUID] {
        let lowered = text.lowercased()
        let hits: [(UUID, String.Index)] = members.compactMap { member in
            var search = lowered.startIndex ..< lowered.endIndex
            while let range = lowered.range(of: "@" + member.handle.lowercased(), range: search) {
                // A handle must end at a non-handle character: @ops must not
                // match inside @opsbot.
                let next = range.upperBound
                if next == lowered.endIndex || !isHandleCharacter(lowered[next]) {
                    return (member.id, range.lowerBound)
                }
                search = next ..< lowered.endIndex
            }
            return nil
        }
        return hits.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Who answers a message the user just posted: whoever it names, or,
    /// when it names nobody, the members set to answer every message.
    static func firstResponders(to text: String, members: [Member]) -> [UUID] {
        let named = mentions(in: text, members: members)
        if !named.isEmpty {
            return named
        }
        return members.filter { $0.respondMode == .everyHumanMessage }.map(\.id)
    }

    /// Adds the members an agent's reply hands over to. The speaker never
    /// queues itself, and nobody is queued twice.
    static func enqueueHandovers(reply: String, speaker: UUID, members: [Member], queue: inout [UUID]) {
        for id in mentions(in: reply, members: members) where id != speaker && !queue.contains(id) {
            queue.append(id)
        }
    }

    static func isHandleCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-"
    }

    /// `^[a-z0-9][a-z0-9_-]{0,30}$` from a display name or slug.
    static func handle(from raw: String) -> String {
        var out = ""
        for c in raw.lowercased() {
            if c.isASCII, c.isLetter || c.isNumber || c == "_" || c == "-" {
                out.append(c)
            } else if c == " " || c == ".", !out.isEmpty, out.last != "-" {
                out.append("-")
            }
        }
        while out.last == "-" {
            out.removeLast()
        }
        while out.first == "-" || out.first == "_" {
            out.removeFirst()
        }
        return out.isEmpty ? "agent" : String(out.prefix(31))
    }

    static func isValidHandle(_ handle: String) -> Bool {
        guard let first = handle.first, handle.count <= 31, first.isASCII, first.isLetter || first.isNumber else { return false }
        return handle.allSatisfy { $0.isASCII && (($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}

/// Asks one member of a room for its reply. Behind a protocol so the
/// orchestrator's tests do not call real agents.
protocol AgentRoomSpeaker: Sendable {
    func reply(
        userID: UUID,
        room: AgentRoom,
        member: AgentRoomMember,
        systemMessage: String,
        message: String,
    ) async throws -> (text: String, tokens: Int?)
}

/// Calls LuminaVault's own agent as a persona, or the user's own Hermes.
struct LiveAgentRoomSpeaker: AgentRoomSpeaker {
    let fluent: Fluent
    let llm: any HermesLLMService
    let agents: AgentsService

    enum Failure: Error, Equatable {
        case noGateway
        case unknownInstance
    }

    func reply(
        userID: UUID,
        room: AgentRoom,
        member: AgentRoomMember,
        systemMessage: String,
        message: String,
    ) async throws -> (text: String, tokens: Int?) {
        let roomID = try room.requireID()
        let memberID = try member.requireID()
        // One Hermes session per member per room, so each agent keeps the
        // room's thread and shows up once on the Agents page.
        let sessionID = "room-\(roomID.uuidString.lowercased())-\(memberID.uuidString.lowercased())"
        switch member.instanceID {
        case AgentsService.centralID:
            let slug = member.profile ?? "default"
            let hermes = try await HermesProfile.query(on: fluent.db())
                .filter(\.$tenantID == userID)
                .first()
            // Same key the chat path composes in HermesProfileMiddleware.
            let key = hermes.map { "\($0.hermesProfileID):\(slug)" } ?? "pending-\(userID.uuidString):\(slug)"
            let response = try await llm.chat(
                sessionKey: key,
                sessionID: sessionID,
                request: ChatRequest(
                    messages: [
                        ChatMessage(role: "system", content: systemMessage),
                        ChatMessage(role: "user", content: message),
                    ],
                    sessionID: sessionID,
                ),
            )
            return (response.message.content, response.raw.usage?.totalTokens)
        case AgentsService.byoID:
            guard let client = await agents.gatewayClient(userID: userID) else { throw Failure.noGateway }
            let reply = try await client.chat(
                sessionID: sessionID,
                title: "Room: \(room.title)",
                systemMessage: systemMessage,
                message: message,
            )
            return (reply.text, reply.totalTokens)
        default:
            throw Failure.unknownInstance
        }
    }
}

/// Runs one chain of agent turns after the user posts in a room.
///
/// The loop guard, all of it enforced here and nowhere else:
/// - at most `AgentRoomTurnPolicy.maxAgentTurns` agent replies per post;
/// - the same agent never answers twice in a row;
/// - the room's token budget, checked before every call;
/// - Stop, re-read from the database between turns;
/// - one chain per room at a time (`AgentRoomRunRegistry`).
struct AgentRoomOrchestrator: Sendable {
    let fluent: Fluent
    let speaker: any AgentRoomSpeaker
    let registry: AgentRoomRunRegistry
    let logger: Logger

    enum RunError: Error, Equatable {
        case alreadyRunning
        case emptyMessage
    }

    static let maxBodyLength = 8000

    /// Posts `body` as the user and runs the chain, reporting each step
    /// through `emit`. Returns why the chain ended.
    @discardableResult
    func post(
        userID: UUID,
        room: AgentRoom,
        body: String,
        emit: @Sendable (AgentRoomStreamEvent) async -> Void,
    ) async throws -> AgentRoomChainEnd {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= Self.maxBodyLength else { throw RunError.emptyMessage }
        let roomID = try room.requireID()
        guard await registry.begin(roomID) else { throw RunError.alreadyRunning }
        do {
            let reason = try await runChain(userID: userID, roomID: roomID, text: text, emit: emit)
            await registry.end(roomID)
            return reason
        } catch {
            await registry.end(roomID)
            throw error
        }
    }

    private func runChain(
        userID: UUID,
        roomID: UUID,
        text: String,
        emit: @Sendable (AgentRoomStreamEvent) async -> Void,
    ) async throws -> AgentRoomChainEnd {
        let chainStart = Date()
        let members = try await AgentRoomMember.query(on: fluent.db())
            .filter(\.$roomID == roomID)
            .sort(\.$createdAt)
            .all()
        let policyMembers = try members.map {
            try AgentRoomTurnPolicy.Member(id: $0.requireID(), handle: $0.handle, respondMode: $0.respondMode)
        }
        let byID = try Dictionary(uniqueKeysWithValues: members.map { try ($0.requireID(), $0) })

        try await emit(.init(kind: .message, message: save(roomID: roomID, kind: .human, memberID: nil, body: text, tokens: nil), memberID: nil, reason: nil))

        var queue = AgentRoomTurnPolicy.firstResponders(to: text, members: policyMembers)
        var lastSpeaker: UUID?
        var turns = 0

        while !queue.isEmpty {
            if Task.isCancelled {
                return .stopped
            }
            guard let current = try await AgentRoom.find(roomID, on: fluent.db()) else { return .stopped }
            if let stop = current.stopRequestedAt, stop >= chainStart {
                return try await end(.stopped, roomID: roomID, note: "Stopped.", emit: emit)
            }
            if turns >= AgentRoomTurnPolicy.maxAgentTurns {
                return try await end(
                    .turnCap, roomID: roomID,
                    note: "Paused after \(AgentRoomTurnPolicy.maxAgentTurns) agent replies. Mention an agent to carry on.",
                    emit: emit,
                )
            }
            if current.spentTokens >= current.tokenBudget {
                return try await end(.budget, roomID: roomID, note: "This room's token budget is spent.", emit: emit)
            }

            let memberID = queue.removeFirst()
            guard memberID != lastSpeaker, let member = byID[memberID] else { continue }

            await emit(.init(kind: .thinking, message: nil, memberID: memberID, reason: nil))
            turns += 1
            lastSpeaker = memberID
            do {
                let message = try await newMessages(for: memberID, roomID: roomID, members: byID)
                let (reply, tokens) = try await speaker.reply(
                    userID: userID,
                    room: current,
                    member: member,
                    systemMessage: Self.preamble(room: current, speaker: member, members: members),
                    message: message,
                )
                let spent = tokens ?? max(1, (message.count + reply.count) / 4)
                current.spentTokens += spent
                try await current.save(on: fluent.db())
                let saved = try await save(roomID: roomID, kind: .agent, memberID: memberID, body: reply, tokens: spent)
                await emit(.init(kind: .message, message: saved, memberID: memberID, reason: nil))
                AgentRoomTurnPolicy.enqueueHandovers(reply: reply, speaker: memberID, members: policyMembers, queue: &queue)
            } catch {
                logger.warning("agent room turn failed", metadata: [
                    "room": .string(roomID.uuidString),
                    "member": .string(memberID.uuidString),
                    "error": .string(Logger.redact(String(describing: error))),
                ])
                let note = try await save(
                    roomID: roomID, kind: .system, memberID: memberID,
                    body: "@\(member.handle) could not answer: \(Self.describe(error))", tokens: nil,
                )
                await emit(.init(kind: .message, message: note, memberID: memberID, reason: nil))
            }
        }
        return .idle
    }

    /// What a member has not seen yet: everything since its own last reply,
    /// or the recent window on its first turn.
    private func newMessages(for memberID: UUID, roomID: UUID, members: [UUID: AgentRoomMember]) async throws -> String {
        let lastOwn = try await AgentRoomMessage.query(on: fluent.db())
            .filter(\.$roomID == roomID)
            .filter(\.$memberID == memberID)
            .filter(\.$authorKindRaw == AgentRoomAuthorKind.agent.rawValue)
            .sort(\.$createdAt, .descending)
            .first()
        var query = AgentRoomMessage.query(on: fluent.db()).filter(\.$roomID == roomID)
        if let since = lastOwn?.createdAt {
            query = query.filter(\.$createdAt > since)
        }
        let rows = try await query.sort(\.$createdAt, .descending).limit(AgentRoomTurnPolicy.firstTurnWindow).all()
        return rows.reversed().map { row in
            switch row.authorKind {
            case .human: "User: \(row.body)"
            case .agent: "@\(row.memberID.flatMap { members[$0]?.handle } ?? "agent"): \(row.body)"
            case .system: "(room: \(row.body))"
            }
        }.joined(separator: "\n\n")
    }

    static func preamble(room: AgentRoom, speaker: AgentRoomMember, members: [AgentRoomMember]) -> String {
        let others = members
            .filter { $0.id != speaker.id }
            .map { "@\($0.handle) (\($0.displayName))" }
            .joined(separator: ", ")
        return """
        You are \(speaker.displayName), @\(speaker.handle), in a LuminaVault room called "\(room.title)" \
        with the user\(others.isEmpty ? "" : " and these agents: \(others)"). \
        The message below is what was said in the room since you last spoke. \
        Reply as yourself only, and keep it short. Do not write lines for the user or the other agents. \
        To hand the conversation to another agent, write their @handle; otherwise do not mention them.
        """
    }

    private func save(roomID: UUID, kind: AgentRoomAuthorKind, memberID: UUID?, body: String, tokens: Int?) async throws -> AgentRoomMessageDTO {
        let row = AgentRoomMessage()
        row.roomID = roomID
        row.authorKind = kind
        row.memberID = memberID
        row.body = body
        row.tokens = tokens
        try await row.save(on: fluent.db())
        return try row.asDTO()
    }

    private func end(
        _ reason: AgentRoomChainEnd,
        roomID: UUID,
        note: String,
        emit: @Sendable (AgentRoomStreamEvent) async -> Void,
    ) async throws -> AgentRoomChainEnd {
        let saved = try await save(roomID: roomID, kind: .system, memberID: nil, body: note, tokens: nil)
        await emit(.init(kind: .message, message: saved, memberID: nil, reason: nil))
        return reason
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case LiveAgentRoomSpeaker.Failure.noGateway: "your Hermes is no longer linked"
        case AgentGatewayClient.Failure.unreachable: "it did not answer"
        case let AgentGatewayClient.Failure.http(status): "it answered HTTP \(status)"
        default: "the call failed"
        }
    }
}

/// One running chain per room. Process-local: the API runs as one replica.
actor AgentRoomRunRegistry {
    private var running: Set<UUID> = []

    func begin(_ roomID: UUID) -> Bool {
        running.insert(roomID).inserted
    }

    func end(_ roomID: UUID) {
        running.remove(roomID)
    }

    func isRunning(_ roomID: UUID) -> Bool {
        running.contains(roomID)
    }
}

extension AgentRoomMessage {
    func asDTO() throws -> AgentRoomMessageDTO {
        try AgentRoomMessageDTO(
            id: requireID(), authorKind: authorKind, memberID: memberID, body: body, tokens: tokens, createdAt: createdAt,
        )
    }
}

extension AgentRoomMember {
    func asDTO() throws -> AgentRoomMemberDTO {
        try AgentRoomMemberDTO(
            id: requireID(), instanceID: instanceID, profile: profile, handle: handle,
            displayName: displayName, respondMode: respondMode,
        )
    }
}
