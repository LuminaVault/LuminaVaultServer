import FluentKit
import Foundation

/// HER-273 — user-facing Hermes "persona" / agent profile. A single
/// user can spin up many of these (`stocks`, `news`, `programming`,
/// …) and switch between them per chat via `X-Hermes-Profile: <slug>`.
///
/// Distinct from `HermesProfile` (the 1:1 Hermes container slot per
/// tenant — that one tracks provisioning state of the user's slice
/// of the Hermes server). This row layers user-facing persona state
/// (label, system prompt, enabled skills) on top of that single
/// container; each `slug` maps to a unique
/// `X-Hermes-Session-Key: <hermesProfileID>:<slug>` so memory and
/// session continuity stay isolated per-persona on the Hermes side.
///
/// `is_default` is the persona used when the request carries no
/// `X-Hermes-Profile` header. Exactly one row per tenant must be
/// flagged default (enforced by the controller + the partial unique
/// index in `M51`).
final class UserHermesProfile: Model, TenantModel, @unchecked Sendable {
    static let schema = "user_hermes_profiles"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "slug") var slug: String
    @Field(key: "label") var label: String
    @Field(key: "system_prompt") var systemPrompt: String
    @Field(key: "is_default") var isDefault: Bool
    @Field(key: "skills_enabled") var skillsEnabled: [String]
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        tenantID: UUID,
        slug: String,
        label: String,
        systemPrompt: String,
        isDefault: Bool,
        skillsEnabled: [String] = []
    ) {
        self.tenantID = tenantID
        self.slug = slug
        self.label = label
        self.systemPrompt = systemPrompt
        self.isDefault = isDefault
        self.skillsEnabled = skillsEnabled
    }
}
