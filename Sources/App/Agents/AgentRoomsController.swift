import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

/// `/v1/agents/rooms` — threads where the user and several of their agents
/// talk. Scoped to the caller's own account.
///
/// Posting a message streams the chain it starts as SSE: the user's message,
/// then `thinking` / `message` frames per agent turn, then `done`.
struct AgentRoomsController {
    let fluent: Fluent
    let agents: AgentsService
    let orchestrator: AgentRoomOrchestrator
    let logger: Logger

    static let maxMembers = 8
    static let maxTitleLength = 120
    static let messagePage = 200

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("room-candidates", use: candidates)
        router.get("rooms", use: list)
        router.post("rooms", use: create)
        router.get("rooms/{room}", use: detail)
        router.delete("rooms/{room}", use: delete)
        router.post("rooms/{room}/messages", use: post)
        router.post("rooms/{room}/stop", use: stop)
    }

    // MARK: - Candidates

    @Sendable
    func candidates(_: Request, ctx: AppRequestContext) async throws -> AgentRoomCandidatesResponse {
        let userID = try ctx.requireTenantID()
        return try await AgentRoomCandidatesResponse(candidates: candidateList(userID: userID))
    }

    /// Every agent the user can seat: each LuminaVault persona, and their own
    /// Hermes when it is linked and answering.
    func candidateList(userID: UUID) async throws -> [AgentRoomCandidateDTO] {
        var out = try await UserHermesProfile.query(on: fluent.db(), tenantID: userID)
            .sort(\.$isDefault, .descending)
            .sort(\.$label)
            .all()
            .map {
                AgentRoomCandidateDTO(
                    instanceID: AgentsService.centralID,
                    profile: $0.slug,
                    displayName: $0.label,
                    suggestedHandle: AgentRoomTurnPolicy.handle(from: $0.slug)
                )
            }
        if let client = await agents.gatewayClient(userID: userID),
           let info = try? await client.instance()
        {
            let profile = info.activeProfile ?? "hermes"
            out.append(AgentRoomCandidateDTO(
                instanceID: AgentsService.byoID,
                profile: nil,
                displayName: "Hermes · \(profile)" + (info.hostname.map { " on \($0)" } ?? ""),
                suggestedHandle: AgentRoomTurnPolicy.handle(from: profile == "default" ? "hermes" : profile)
            ))
        }
        return out
    }

    // MARK: - Rooms

    @Sendable
    func list(_: Request, ctx: AppRequestContext) async throws -> AgentRoomsResponse {
        let userID = try ctx.requireTenantID()
        let rooms = try await AgentRoom.query(on: fluent.db(), tenantID: userID)
            .sort(\.$updatedAt, .descending)
            .limit(100)
            .all()
        var out: [AgentRoomDTO] = []
        for room in rooms {
            try await out.append(dto(room))
        }
        return AgentRoomsResponse(rooms: out)
    }

    @Sendable
    func create(_ req: Request, ctx: AppRequestContext) async throws -> AgentRoomDetailResponse {
        let userID = try ctx.requireTenantID()
        let body = try await req.decode(as: AgentRoomCreateRequest.self, context: ctx)
        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= Self.maxTitleLength else {
            throw HTTPError(.badRequest, message: "invalid_title")
        }
        guard (1 ... Self.maxMembers).contains(body.members.count) else {
            throw HTTPError(.badRequest, message: "invalid_member_count")
        }
        let available = try await candidateList(userID: userID)
        let members = try Self.resolveMembers(body.members, available: available)

        let room = AgentRoom()
        room.tenantID = userID
        room.title = title
        room.tokenBudget = 200_000
        room.spentTokens = 0
        try await fluent.db().transaction { db in
            try await room.save(on: db)
            let roomID = try room.requireID()
            for member in members {
                member.roomID = roomID
                try await member.save(on: db)
            }
        }
        return try await AgentRoomDetailResponse(room: dto(room), messages: [])
    }

    /// Validates requested members against what the user can actually seat.
    /// Internal for tests.
    static func resolveMembers(_ requested: [AgentRoomMemberRequest], available: [AgentRoomCandidateDTO]) throws -> [AgentRoomMember] {
        var handles: Set<String> = []
        var seatedByo = false
        return try requested.map { request in
            guard let candidate = available.first(where: {
                $0.instanceID == request.instanceID && $0.profile == request.profile
            }) else {
                throw HTTPError(.badRequest, message: "unknown_member")
            }
            if candidate.instanceID == AgentsService.byoID {
                // One linked gateway answers as one profile: a second seat
                // would be the same agent twice.
                guard !seatedByo else { throw HTTPError(.badRequest, message: "duplicate_member") }
                seatedByo = true
            }
            let handle = (request.handle?.trimmingCharacters(in: .whitespaces).lowercased()).flatMap { $0.isEmpty ? nil : $0 }
                ?? candidate.suggestedHandle
            guard AgentRoomTurnPolicy.isValidHandle(handle) else { throw HTTPError(.badRequest, message: "invalid_handle") }
            guard handles.insert(handle).inserted else { throw HTTPError(.badRequest, message: "duplicate_handle") }
            let member = AgentRoomMember()
            member.instanceID = candidate.instanceID
            member.profile = candidate.profile
            member.handle = handle
            let name = request.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            member.displayName = name.isEmpty ? candidate.displayName : String(name.prefix(60))
            member.respondMode = request.respondMode ?? .mention
            return member
        }
    }

    @Sendable
    func detail(_: Request, ctx: AppRequestContext) async throws -> AgentRoomDetailResponse {
        let room = try await ownedRoom(ctx)
        let rows = try await AgentRoomMessage.query(on: fluent.db())
            .filter(\.$roomID == room.requireID())
            .sort(\.$createdAt, .descending)
            .limit(Self.messagePage)
            .all()
        return try await AgentRoomDetailResponse(room: dto(room), messages: rows.reversed().map { try $0.asDTO() })
    }

    @Sendable
    func delete(_: Request, ctx: AppRequestContext) async throws -> Response {
        let room = try await ownedRoom(ctx)
        try await room.delete(on: fluent.db())
        return Response(status: .noContent)
    }

    @Sendable
    func stop(_: Request, ctx: AppRequestContext) async throws -> Response {
        let room = try await ownedRoom(ctx)
        room.stopRequestedAt = Date()
        try await room.save(on: fluent.db())
        return Response(status: .accepted)
    }

    @Sendable
    func post(_ req: Request, ctx: AppRequestContext) async throws -> EncodableSSEStreamResponse<AgentRoomStreamEvent> {
        let userID = try ctx.requireTenantID()
        let room = try await ownedRoom(ctx)
        let body = try await req.decode(as: AgentRoomPostRequest.self, context: ctx)
        let text = body.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= AgentRoomOrchestrator.maxBodyLength else {
            throw HTTPError(.badRequest, message: "invalid_body")
        }
        // Refuse before the stream opens, so a second tab gets a clean 409.
        guard try await !orchestrator.registry.isRunning(room.requireID()) else {
            throw HTTPError(.conflict, message: "room_busy")
        }

        let (events, continuation) = AsyncThrowingStream<AgentRoomStreamEvent, Error>.makeStream()
        let orchestrator = orchestrator
        let logger = logger
        // Closing the stream (the user left) cancels the chain; it stops
        // before the next agent turn.
        let task = Task {
            do {
                let reason = try await orchestrator.post(userID: userID, room: room, body: text) { event in
                    continuation.yield(event)
                }
                continuation.yield(.init(kind: .done, message: nil, memberID: nil, reason: reason))
                continuation.finish()
            } catch {
                logger.warning("agent room chain failed", metadata: ["error": .string(Logger.redact(String(describing: error)))])
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return EncodableSSEStreamResponse(events: events, eventName: "agent.room")
    }

    // MARK: - Helpers

    private func ownedRoom(_ ctx: AppRequestContext) async throws -> AgentRoom {
        let userID = try ctx.requireTenantID()
        guard let id = ctx.parameters.get("room", as: UUID.self),
              let room = try await AgentRoom.query(on: fluent.db(), tenantID: userID).filter(\.$id == id).first()
        else {
            throw HTTPError(.notFound, message: "room_not_found")
        }
        return room
    }

    private func dto(_ room: AgentRoom) async throws -> AgentRoomDTO {
        let members = try await AgentRoomMember.query(on: fluent.db())
            .filter(\.$roomID == room.requireID())
            .sort(\.$createdAt)
            .all()
        return try AgentRoomDTO(
            id: room.requireID(),
            title: room.title,
            tokenBudget: room.tokenBudget,
            spentTokens: room.spentTokens,
            members: members.map { try $0.asDTO() },
            createdAt: room.createdAt,
            updatedAt: room.updatedAt
        )
    }
}
