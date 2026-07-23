import FluentKit
import Foundation
import LuminaVaultShared

struct RouterProfileDocument: Codable, Equatable {
    var objective: RouterObjectiveWeightsDTO
    var budget: RouterBudgetPolicyDTO
    var allowedProviders: [ProviderID]
    var blockedProviders: [ProviderID]
    var defaultAction: RouterActionDTO
    var rules: [RouterRuleDTO]
    /// Task-aware routing policy. Missing in legacy rows → `autoSmart`.
    var routingPolicy: LLMRoutingPolicy

    init(
        objective: RouterObjectiveWeightsDTO,
        budget: RouterBudgetPolicyDTO,
        allowedProviders: [ProviderID],
        blockedProviders: [ProviderID],
        defaultAction: RouterActionDTO,
        rules: [RouterRuleDTO],
        routingPolicy: LLMRoutingPolicy = .autoSmart
    ) {
        self.objective = objective
        self.budget = budget
        self.allowedProviders = allowedProviders
        self.blockedProviders = blockedProviders
        self.defaultAction = defaultAction
        self.rules = rules
        self.routingPolicy = routingPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case objective, budget, allowedProviders, blockedProviders
        case defaultAction, rules, routingPolicy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        objective = try c.decode(RouterObjectiveWeightsDTO.self, forKey: .objective)
        budget = try c.decode(RouterBudgetPolicyDTO.self, forKey: .budget)
        allowedProviders = try c.decodeIfPresent([ProviderID].self, forKey: .allowedProviders) ?? []
        blockedProviders = try c.decodeIfPresent([ProviderID].self, forKey: .blockedProviders) ?? []
        defaultAction = try c.decode(RouterActionDTO.self, forKey: .defaultAction)
        rules = try c.decodeIfPresent([RouterRuleDTO].self, forKey: .rules) ?? []
        routingPolicy = try c.decodeIfPresent(LLMRoutingPolicy.self, forKey: .routingPolicy) ?? .autoSmart
    }
}

final class RouterProfile: Model, TenantModel, @unchecked Sendable {
    static let schema = "router_profiles"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "name") var name: String
    @Field(key: "mode") var mode: String
    @Field(key: "is_preset") var isPreset: Bool
    @Field(key: "document") var document: RouterProfileDocument
    @Field(key: "revision") var revision: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

final class RouterBinding: Model, TenantModel, @unchecked Sendable {
    static let schema = "router_bindings"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "scope") var scope: String
    @Field(key: "scope_id") var scopeID: String
    @Field(key: "profile_id") var profileID: UUID
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}
