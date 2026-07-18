import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared
import SQLKit

extension RouterProfilesResponse: @retroactive ResponseEncodable {}
extension RouterProfileDTO: @retroactive ResponseEncodable {}
extension RouterBindingsResponse: @retroactive ResponseEncodable {}
extension RouterBindingDTO: @retroactive ResponseEncodable {}
extension RouterCatalogResponse: @retroactive ResponseEncodable {}
extension RouterDashboardResponse: @retroactive ResponseEncodable {}

struct RouterController {
    let repository: RouterProfileRepository
    let fluent: Fluent
    let ensemblesEnabled: Bool

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
        router.post("", use: create)
        router.get("/catalog", use: catalog)
        router.get("/bindings", use: bindings)
        router.put("/bindings/:scope/:scopeID", use: putBinding)
        router.delete("/bindings/:scope/:scopeID", use: deleteBinding)
        router.get("/dashboard", use: dashboard)
        router.put("/:id", use: update)
        router.delete("/:id", use: delete)
    }

    @Sendable
    func list(_: Request, ctx: AppRequestContext) async throws -> RouterProfilesResponse {
        try await repository.list(tenantID: ctx.requireTenantID())
    }

    @Sendable
    func create(_ req: Request, ctx: AppRequestContext) async throws -> RouterProfileDTO {
        let user = try ctx.requireIdentity()
        guard Self.isProOrUltimate(user) else { throw HTTPError(.forbidden, message: "router_custom_profile_requires_pro") }
        let body = try await req.decode(as: RouterProfileWriteRequest.self, context: ctx)
        try Self.validate(body, user: user, ensemblesEnabled: ensemblesEnabled)
        return try await repository.create(tenantID: user.requireID(), request: body)
    }

    @Sendable
    func update(_ req: Request, ctx: AppRequestContext) async throws -> RouterProfileDTO {
        let user = try ctx.requireIdentity()
        let id = try Self.pathID(ctx, name: "id")
        let body = try await req.decode(as: RouterProfileWriteRequest.self, context: ctx)
        try Self.validate(body, user: user, ensemblesEnabled: ensemblesEnabled)
        do {
            guard let result = try await repository.update(tenantID: user.requireID(), id: id, request: body) else {
                throw HTTPError(.notFound, message: "router_profile_not_found")
            }
            return result
        } catch RouterProfileRepositoryError.revisionConflict {
            throw HTTPError(.conflict, message: "router_profile_revision_conflict")
        }
    }

    @Sendable
    func delete(_: Request, ctx: AppRequestContext) async throws -> Response {
        let user = try ctx.requireIdentity()
        guard Self.isProOrUltimate(user) else { throw HTTPError(.forbidden, message: "router_custom_profile_requires_pro") }
        let id = try Self.pathID(ctx, name: "id")
        do {
            guard try await repository.delete(tenantID: user.requireID(), id: id) else {
                throw HTTPError(.notFound, message: "router_profile_not_found")
            }
        } catch RouterProfileRepositoryError.cannotDeleteDefault {
            throw HTTPError(.conflict, message: "router_default_profile_cannot_be_deleted")
        }
        return Response(status: .noContent)
    }

    @Sendable
    func catalog(_: Request, ctx: AppRequestContext) async throws -> RouterCatalogResponse {
        let user = try ctx.requireIdentity()
        return RouterCatalogResponse(
            models: RouterModelCatalog.entries,
            customProfilesAllowed: Self.isProOrUltimate(user),
            ensemblesAllowed: ensemblesEnabled && Self.isUltimate(user)
        )
    }

    @Sendable
    func bindings(_: Request, ctx: AppRequestContext) async throws -> RouterBindingsResponse {
        try await repository.bindings(tenantID: ctx.requireTenantID())
    }

    @Sendable
    func putBinding(_ req: Request, ctx: AppRequestContext) async throws -> RouterBindingDTO {
        let user = try ctx.requireIdentity()
        let scope = try Self.bindingScope(ctx)
        if scope != .user, !Self.isProOrUltimate(user) {
            throw HTTPError(.forbidden, message: "router_scoped_profile_requires_pro")
        }
        let requestedScopeID = try Self.scopeID(ctx)
        let scopeID = scope == .user ? try user.requireID().uuidString : requestedScopeID
        try await validateScopeOwnership(tenantID: user.requireID(), scope: scope, scopeID: scopeID)
        let body = try await req.decode(as: RouterBindingPutRequest.self, context: ctx)
        do {
            return try await repository.bind(
                tenantID: user.requireID(),
                scope: scope,
                scopeID: scopeID,
                profileID: body.profileID
            )
        } catch RouterProfileRepositoryError.profileNotFound {
            throw HTTPError(.notFound, message: "router_profile_not_found")
        }
    }

    @Sendable
    func deleteBinding(_: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try ctx.requireTenantID()
        let scope = try Self.bindingScope(ctx)
        let scopeID = try Self.scopeID(ctx)
        _ = try await repository.unbind(tenantID: tenantID, scope: scope, scopeID: scopeID)
        return Response(status: .noContent)
    }

    @Sendable
    func dashboard(_: Request, ctx: AppRequestContext) async throws -> RouterDashboardResponse {
        let tenantID = try ctx.requireTenantID()
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "sql_unavailable")
        }
        struct Row: Decodable {
            let requests: Int64
            let successful: Int64
            let fallback_count: Int64
            let tokens_in: Int64
            let tokens_out: Int64
            let cost: Int64
            let latency: Int64
        }
        let row = try await sql.raw("""
        SELECT COUNT(*) AS requests,
               COUNT(*) FILTER (WHERE status = 'ok') AS successful,
               COALESCE(SUM(fallback_count), 0) AS fallback_count,
               COALESCE(SUM(tokens_in), 0) AS tokens_in,
               COALESCE(SUM(tokens_out), 0) AS tokens_out,
               COALESCE(SUM(estimated_cost_usd_micros), 0) AS cost,
               COALESCE(AVG(latency_ms), 0)::bigint AS latency
        FROM router_executions
        WHERE tenant_id = \(bind: tenantID)
          AND occurred_at >= date_trunc('month', NOW())
        """).first(decoding: Row.self)
        let profiles = try await repository.list(tenantID: tenantID)
        let defaultProfile = profiles.profiles.first { $0.id == profiles.defaultProfileID }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = Date()
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        return RouterDashboardResponse(
            periodStart: start,
            periodEnd: now,
            requests: Int(row?.requests ?? 0),
            successfulRequests: Int(row?.successful ?? 0),
            fallbackCount: Int(row?.fallback_count ?? 0),
            tokensIn: Int(row?.tokens_in ?? 0),
            tokensOut: Int(row?.tokens_out ?? 0),
            estimatedCostUsdMicros: row?.cost ?? 0,
            averageLatencyMs: Int(row?.latency ?? 0),
            monthlySoftLimitUsdMicros: defaultProfile?.budget.softLimitUsdMicros,
            monthlyHardLimitUsdMicros: defaultProfile?.budget.hardLimitUsdMicros
        )
    }

    private func validateScopeOwnership(tenantID: UUID, scope: RouterBindingScope, scopeID: String) async throws {
        switch scope {
        case .space:
            guard let id = UUID(uuidString: scopeID),
                  try await Space.query(on: fluent.db(), tenantID: tenantID).filter(\.$id == id).first() != nil
            else { throw HTTPError(.notFound, message: "space_not_found") }
        case .job:
            guard let sql = fluent.db() as? any SQLDatabase else { throw HTTPError(.internalServerError) }
            let exists = try await sql.raw("""
            SELECT 1 FROM skills_state WHERE tenant_id = \(bind: tenantID) AND name = \(bind: scopeID) LIMIT 1
            """).first() != nil
            guard exists else { throw HTTPError(.notFound, message: "job_not_found") }
        case .workflow:
            guard let id = UUID(uuidString: scopeID),
                  try await Workflow.query(on: fluent.db(), tenantID: tenantID).filter(\.$id == id).first() != nil
            else { throw HTTPError(.notFound, message: "workflow_not_found") }
        case .user:
            guard scopeID == tenantID.uuidString else {
                throw HTTPError(.forbidden, message: "router_user_scope_mismatch")
            }
        }
    }

    private static func validate(
        _ body: RouterProfileWriteRequest,
        user: User,
        ensemblesEnabled: Bool
    ) throws {
        guard !body.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HTTPError(.badRequest, message: "router_profile_name_required")
        }
        guard body.objective.quality >= 0, body.objective.cost >= 0, body.objective.latency >= 0,
              body.objective.quality + body.objective.cost + body.objective.latency == 100
        else { throw HTTPError(.badRequest, message: "router_objective_weights_must_total_100") }
        if body.mode == .byok, !isUltimate(user) {
            throw HTTPError(.forbidden, message: "router_byok_requires_ultimate")
        }
        if let soft = body.budget.softLimitUsdMicros, let hard = body.budget.hardLimitUsdMicros,
           soft > hard
        {
            throw HTTPError(.badRequest, message: "router_soft_budget_exceeds_hard_budget")
        }
        let actions = [body.defaultAction] + body.rules.map(\.action)
        for action in actions {
            guard !action.routes.isEmpty else { throw HTTPError(.badRequest, message: "router_action_requires_route") }
            if action.kind == .ensemble {
                guard ensemblesEnabled, isUltimate(user) else {
                    throw HTTPError(.forbidden, message: "router_ensemble_requires_ultimate")
                }
                guard (2 ... 4).contains(action.routes.count), action.synthesisRoute != nil else {
                    throw HTTPError(.badRequest, message: "router_ensemble_invalid")
                }
            }
            for route in action.routes where route.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw HTTPError(.badRequest, message: "router_model_required")
            }
        }
    }

    private static func isProOrUltimate(_ user: User) -> Bool {
        let effective = EntitlementChecker.effectiveTier(tier: user.tierEnum, override: user.tierOverrideEnum)
        return effective == .pro || effective == .ultimate
    }

    private static func isUltimate(_ user: User) -> Bool {
        EntitlementChecker.effectiveTier(tier: user.tierEnum, override: user.tierOverrideEnum) == .ultimate
    }

    private static func pathID(_ ctx: AppRequestContext, name: String) throws -> UUID {
        guard let raw = ctx.parameters.get(name), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid_\(name)")
        }
        return id
    }

    private static func bindingScope(_ ctx: AppRequestContext) throws -> RouterBindingScope {
        guard let raw = ctx.parameters.get("scope"), let scope = RouterBindingScope(rawValue: raw) else {
            throw HTTPError(.badRequest, message: "invalid_router_scope")
        }
        return scope
    }

    private static func scopeID(_ ctx: AppRequestContext) throws -> String {
        guard let id = ctx.parameters.get("scopeID"), !id.isEmpty else {
            throw HTTPError(.badRequest, message: "router_scope_id_required")
        }
        return id
    }
}
