import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import SQLKit

/// One list of a user's agents and their sessions, wherever they run.
///
/// Two sources:
/// - **central** — LuminaVault's own agent. Its sessions are the user's
///   `conversations`, read from our database. The shared `hermes-production`
///   gateway is never asked: its `/api/sessions` holds every tenant's rows.
/// - **byo** — the user's own Hermes gateway (`user_hermes_config`), reached
///   through `HermesEndpointResolver` so the SSRF guard and sealed key apply.
///   One gateway reports every profile on its machine.
///
/// Read-only. Every call is scoped to the caller's own account.
struct AgentsService: Sendable {
    static let centralID = "central"
    static let byoID = "byo"
    static let centralSource = "app"
    static let activeWindow: TimeInterval = 300

    let fluent: Fluent
    /// `nil` when this deployment has no Hermes configured at all.
    let resolver: HermesEndpointResolver?
    let http: any HermesHTTPExecuting
    let logger: Logger

    struct Filter: Sendable {
        var instanceID: String?
        var profile: String?
        var source: String?
        var liveOnly = false
        var limit = 50
    }

    enum LookupError: Error, Equatable {
        case unknownInstance
        case sessionNotFound
        case gateway(AgentGatewayClient.Failure)
    }

    // MARK: - Instances

    func instances(userID: UUID) async -> [AgentInstanceDTO] {
        var out = [Self.centralInstance]
        if let byo = await byoInstance(userID: userID) {
            out.append(byo)
        }
        return out
    }

    static let centralInstance = AgentInstanceDTO(
        id: centralID,
        kind: .central,
        name: "LuminaVault agent",
        status: .ok,
        hostname: nil,
        version: nil,
        profiles: [],
        platforms: ["app", "web"]
    )

    private func byoInstance(userID: UUID) async -> AgentInstanceDTO? {
        guard let client = await gatewayClient(userID: userID) else { return nil }
        async let platforms = client.connectedPlatforms()
        do {
            let info = try await client.instance()
            return await AgentInstanceDTO(
                id: Self.byoID, kind: .byo, name: info.hostname ?? "Your Hermes", status: .ok,
                hostname: info.hostname, version: info.version, profiles: info.profiles, platforms: platforms
            )
        } catch AgentGatewayClient.Failure.notSupported {
            return await AgentInstanceDTO(
                id: Self.byoID, kind: .byo, name: "Your Hermes", status: .outdated,
                hostname: nil, version: nil, profiles: [], platforms: platforms
            )
        } catch {
            _ = await platforms
            return AgentInstanceDTO(
                id: Self.byoID, kind: .byo, name: "Your Hermes", status: .unreachable,
                hostname: nil, version: nil, profiles: [], platforms: []
            )
        }
    }

    // MARK: - Sessions

    func sessions(userID: UUID, filter: Filter) async -> AgentSessionsResponse {
        let wantsCentral = filter.instanceID == nil || filter.instanceID == Self.centralID
        let wantsByo = filter.instanceID == nil || filter.instanceID == Self.byoID

        async let central: Result<[AgentSessionDTO], any Error> = wantsCentral && centralMatches(filter)
            ? capture { try await centralSessions(userID: userID, limit: filter.limit) }
            : .success([])
        async let byo: Result<[AgentSessionDTO], any Error> = wantsByo
            ? capture { try await byoSessions(userID: userID, filter: filter) }
            : .success([])

        var sessions: [AgentSessionDTO] = []
        var errors: [AgentInstanceErrorDTO] = []
        for (instanceID, result) in await [(Self.centralID, central), (Self.byoID, byo)] {
            switch result {
            case let .success(rows): sessions += rows
            case let .failure(error):
                logger.warning("agents.sessions instance failed", metadata: ["instance": "\(instanceID)", "error": "\(error)"])
                errors.append(AgentInstanceErrorDTO(instanceID: instanceID, message: Self.describe(error)))
            }
        }
        if filter.liveOnly {
            sessions = sessions.filter(\.isActive)
        }
        sessions.sort { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }
        return AgentSessionsResponse(sessions: Array(sessions.prefix(filter.limit)), errors: errors)
    }

    private func centralMatches(_ filter: Filter) -> Bool {
        filter.profile == nil && (filter.source == nil || filter.source == Self.centralSource)
    }

    private func centralSessions(userID: UUID, limit: Int) async throws -> [AgentSessionDTO] {
        guard let sql = fluent.db() as? any SQLDatabase else { throw HTTPError(.internalServerError) }
        struct Row: Decodable {
            let id: UUID
            let title: String
            let created_at: Date?
            let updated_at: Date?
            let message_count: Int
        }
        let rows = try await sql.raw("""
        SELECT c.id, c.title, c.created_at, c.updated_at, COUNT(m.id)::int AS message_count
        FROM conversations c
        LEFT JOIN conversation_messages m ON m.conversation_id = c.id
        WHERE c.tenant_id = \(bind: userID)
        GROUP BY c.id
        ORDER BY c.updated_at DESC NULLS LAST
        LIMIT \(bind: limit)
        """).all(decoding: Row.self)
        let now = Date()
        return rows.map { row in
            let last = row.updated_at ?? row.created_at
            return AgentSessionDTO(
                instanceID: Self.centralID,
                profile: nil,
                id: row.id.uuidString,
                title: row.title.isEmpty ? nil : row.title,
                source: Self.centralSource,
                startedAt: row.created_at,
                lastActiveAt: last,
                messageCount: row.message_count,
                isActive: last.map { now.timeIntervalSince($0) < Self.activeWindow } ?? false,
                costUSD: nil
            )
        }
    }

    private func byoSessions(userID: UUID, filter: Filter) async throws -> [AgentSessionDTO] {
        guard let client = await gatewayClient(userID: userID) else { return [] }
        let page = try await client.sessions(
            instanceID: Self.byoID, profile: filter.profile, source: filter.source, limit: filter.limit
        )
        // An old Hermes cannot filter by profile; showing its one profile's
        // rows under a profile filter would mislabel them.
        if filter.profile != nil, !page.profileAware {
            return []
        }
        return page.sessions
    }

    // MARK: - Messages

    func messages(userID: UUID, instanceID: String, profile: String?, sessionID: String) async throws -> AgentSessionMessagesResponse {
        switch instanceID {
        case Self.centralID:
            return try await centralMessages(userID: userID, sessionID: sessionID)
        case Self.byoID:
            guard let client = await gatewayClient(userID: userID) else { throw LookupError.unknownInstance }
            do {
                let (resolved, messages) = try await client.messages(profile: profile, sessionID: sessionID)
                return AgentSessionMessagesResponse(
                    instanceID: instanceID, profile: profile, sessionID: resolved, messages: messages
                )
            } catch AgentGatewayClient.Failure.http(404) {
                throw LookupError.sessionNotFound
            } catch let failure as AgentGatewayClient.Failure {
                throw LookupError.gateway(failure)
            }
        default:
            throw LookupError.unknownInstance
        }
    }

    private func centralMessages(userID: UUID, sessionID: String) async throws -> AgentSessionMessagesResponse {
        // Ownership first: a conversation id alone is not proof of access.
        guard let id = UUID(uuidString: sessionID),
              try await Conversation.query(on: fluent.db())
              .filter(\.$id == id)
              .filter(\.$tenantID == userID)
              .first() != nil
        else {
            throw LookupError.sessionNotFound
        }
        let rows = try await ConversationMessage.query(on: fluent.db())
            .filter(\.$conversationID == id)
            .sort(\.$createdAt, .ascending)
            .all()
        return AgentSessionMessagesResponse(
            instanceID: Self.centralID,
            profile: nil,
            sessionID: sessionID,
            messages: rows.map {
                AgentMessageDTO(role: $0.role, content: $0.content, toolName: nil, toolCalls: nil, createdAt: $0.createdAt)
            }
        )
    }

    // MARK: - Helpers

    /// The user's own gateway, or `nil` when they have none (or it is
    /// unusable — a broken BYO config must not take the page down).
    func gatewayClient(userID: UUID) async -> AgentGatewayClient? {
        guard let resolver else { return nil }
        do {
            let resolution = try await resolver.resolve(tenantID: userID)
            guard resolution.isUserOverride else { return nil }
            return AgentGatewayClient(
                baseURL: resolution.baseURL, authHeader: resolution.authHeader, http: http, logger: logger
            )
        } catch {
            logger.warning("agents: byo gateway unusable", metadata: ["error": "\(error)"])
            return nil
        }
    }

    private func capture(_ body: () async throws -> [AgentSessionDTO]) async -> Result<[AgentSessionDTO], any Error> {
        do { return try await .success(body()) } catch { return .failure(error) }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case AgentGatewayClient.Failure.unreachable: "Your Hermes did not answer."
        case let AgentGatewayClient.Failure.http(status) where status == 401 || status == 403:
            "Your Hermes rejected the saved key."
        case let AgentGatewayClient.Failure.http(status): "Your Hermes answered HTTP \(status)."
        case AgentGatewayClient.Failure.invalidResponse: "Your Hermes sent a response we could not read."
        default: "Sessions could not be loaded."
        }
    }
}
