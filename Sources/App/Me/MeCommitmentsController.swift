import Foundation
import Hummingbird
import LuminaVaultShared

extension CommitmentsResponse: @retroactive ResponseEncodable {}
extension CommitmentDTO: @retroactive ResponseEncodable {}

/// `GET /v1/me/commitments?state=open|done|dropped|all` (default `open`) and
/// `PATCH /v1/me/commitments/{id} { state }`. The caller's own commitments
/// only; another tenant's id is a 404. Mounted with `/v1/me/today` (JWT +
/// per-user rate limit, no entitlement gate).
struct MeCommitmentsController {
    let service: CommitmentsService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/commitments", use: list)
        router.patch("/commitments/:id", use: update)
    }

    @Sendable
    func list(_ request: Request, ctx: AppRequestContext) async throws -> CommitmentsResponse {
        let user = try ctx.requireIdentity()
        let filter = try Self.parseState(request.uri.queryParameters["state"].map(String.init))
        return try await CommitmentsResponse(items: service.list(tenantID: user.requireID(), filter: filter))
    }

    @Sendable
    func update(_ request: Request, ctx: AppRequestContext) async throws -> CommitmentDTO {
        let user = try ctx.requireIdentity()
        guard let raw = ctx.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid commitment id")
        }
        let body = try await request.decode(as: CommitmentUpdateRequest.self, context: ctx)
        guard let updated = try await service.update(tenantID: user.requireID(), id: id, state: body.state) else {
            throw HTTPError(.notFound, message: "commitment not found")
        }
        return updated
    }

    /// Missing → `open`. Anything but open|done|dropped|all is a 400.
    static func parseState(_ raw: String?) throws -> CommitmentsService.Filter {
        guard let raw, !raw.isEmpty else { return .open }
        guard let filter = CommitmentsService.Filter(rawValue: raw) else {
            throw HTTPError(.badRequest, message: "state must be open, done, dropped or all")
        }
        return filter
    }
}
