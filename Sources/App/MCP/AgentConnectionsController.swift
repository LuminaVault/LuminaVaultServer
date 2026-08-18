import Foundation
import Hummingbird
import Logging

/// `/v1/me/agent-connections` — issue, list, preview, revoke the
/// personal tokens an outside agent uses on `/v1/mcp`.
struct AgentConnectionsController {
    let service: AgentConnectionService
    let publicBaseURL: String
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get(use: list)
        router.post(use: issue)
        router.get("preview", use: preview)
        router.delete("{id}", use: revoke)
    }

    @Sendable
    func list(_: Request, ctx: AppRequestContext) async throws -> AgentConnectionsListResponse {
        let tenantID = try ctx.requireTenantID()
        let connections = try await service.list(tenantID: tenantID)
        return AgentConnectionsListResponse(connections: connections)
    }

    @Sendable
    func issue(_ req: Request, ctx: AppRequestContext) async throws -> AgentConnectionIssuedResponse {
        let tenantID = try ctx.requireTenantID()
        let body = try await req.decode(as: AgentConnectionIssueRequest.self, context: ctx)
        let (connection, token) = try await service.issue(
            tenantID: tenantID,
            name: body.name,
            kind: body.clientKind
        )
        let setup = MCPSetup.instructions(
            kind: body.clientKind,
            publicBaseURL: publicBaseURL,
            token: token
        )
        return AgentConnectionIssuedResponse(connection: connection, token: token, setup: setup)
    }

    @Sendable
    func preview(_ req: Request, ctx: AppRequestContext) throws -> AgentConnectionSetupDTO {
        _ = try ctx.requireTenantID()
        let raw = req.uri.queryParameters["clientKind"].map(String.init) ?? AgentClientKind.other.rawValue
        guard let kind = AgentClientKind(rawValue: raw) else {
            throw HTTPError(.badRequest, message: "invalid_client_kind")
        }
        return MCPSetup.preview(kind: kind, publicBaseURL: publicBaseURL)
    }

    @Sendable
    func revoke(_ req: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try ctx.requireTenantID()
        guard let id = ctx.parameters.get("id", as: UUID.self) else {
            throw HTTPError(.badRequest, message: "invalid_id")
        }
        try await service.revoke(id: id, tenantID: tenantID)
        return Response(status: .noContent)
    }
}
