import FluentKit
import Foundation
import LuminaVaultShared

struct RouterProfileDocument: Codable, Sendable {
    var objective: RouterObjectiveWeightsDTO
    var budget: RouterBudgetPolicyDTO
    var allowedProviders: [ProviderID]
    var blockedProviders: [ProviderID]
    var defaultAction: RouterActionDTO
    var rules: [RouterRuleDTO]
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
