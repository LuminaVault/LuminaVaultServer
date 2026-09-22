import Foundation
import Hummingbird
import Logging

/// `/v1/agents` — the Agents page: where the user's agents run, their
/// sessions, and each session's log. Read-only.
///
/// Always scoped to the caller's own account; `X-Vault-ID` does not apply,
/// because agents belong to a person, not to a shared vault.
struct AgentsController {
    let service: AgentsService
    let logger: Logger

    private static let maxLimit = 200
    private static let defaultLimit = 50

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("instances", use: instances)
        router.get("sessions", use: sessions)
        router.get("instances/{instance}/sessions/{session}/messages", use: messages)
    }

    @Sendable
    func instances(_: Request, ctx: AppRequestContext) async throws -> AgentInstancesResponse {
        let userID = try ctx.requireTenantID()
        return await AgentInstancesResponse(instances: service.instances(userID: userID))
    }

    @Sendable
    func sessions(_ req: Request, ctx: AppRequestContext) async throws -> AgentSessionsResponse {
        let userID = try ctx.requireTenantID()
        let query = req.uri.queryParameters
        var filter = AgentsService.Filter()
        filter.instanceID = Self.nonEmpty(query["instance"])
        filter.profile = Self.nonEmpty(query["profile"])
        filter.source = Self.nonEmpty(query["source"])
        filter.liveOnly = query["live"].map { $0 == "true" || $0 == "1" } ?? false
        if let raw = query["limit"].flatMap({ Int(String($0)) }) {
            filter.limit = max(1, min(raw, Self.maxLimit))
        } else {
            filter.limit = Self.defaultLimit
        }
        if let instance = filter.instanceID, ![AgentsService.centralID, AgentsService.byoID].contains(instance) {
            throw HTTPError(.badRequest, message: "unknown_instance")
        }
        return await service.sessions(userID: userID, filter: filter)
    }

    @Sendable
    func messages(_ req: Request, ctx: AppRequestContext) async throws -> AgentSessionMessagesResponse {
        let userID = try ctx.requireTenantID()
        guard let instance = ctx.parameters.get("instance"),
              let session = ctx.parameters.get("session")
        else {
            throw HTTPError(.badRequest, message: "invalid_path")
        }
        let profile = Self.nonEmpty(req.uri.queryParameters["profile"])
        do {
            return try await service.messages(userID: userID, instanceID: instance, profile: profile, sessionID: session)
        } catch AgentsService.LookupError.unknownInstance {
            throw HTTPError(.notFound, message: "unknown_instance")
        } catch AgentsService.LookupError.sessionNotFound {
            throw HTTPError(.notFound, message: "session_not_found")
        } catch AgentsService.LookupError.gateway(.invalidID) {
            throw HTTPError(.badRequest, message: "invalid_session_id")
        } catch let AgentsService.LookupError.gateway(failure) {
            throw HTTPError(.badGateway, message: AgentsService.describe(failure))
        }
    }

    private static func nonEmpty(_ value: Substring?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(value)
    }
}
