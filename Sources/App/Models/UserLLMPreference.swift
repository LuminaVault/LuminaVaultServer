import FluentKit
import Foundation

/// HER-252 — per-tenant LLM routing preference: primary `(provider,
/// model)` + ordered fallback chain. Consulted by
/// `UserPreferenceModelRouter` on every chat / query / kb-compile call.
///
/// 1:1 with `users` via `tenant_id UNIQUE`. Row absent ⇒ fall through to
/// the static `TableModelRouter` table. `fallbackChain` is JSON so we
/// store an ordered array of `{provider, model}` without a side table.
final class UserLLMPreference: Model, TenantModel, @unchecked Sendable {
    static let schema = "user_llm_preferences"

    struct FallbackStep: Codable, Hashable {
        let provider: String
        let model: String
    }

    /// HER-300 — distinguishes server-managed default routing from
    /// user-supplied API keys (BYOK). Mirrors the wire `LLMBrainMode`.
    enum Mode: String, CaseIterable {
        case managed
        case byok
    }

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "mode") var mode: String
    @Field(key: "primary_provider") var primaryProvider: String
    @Field(key: "primary_model") var primaryModel: String
    @Field(key: "fallback_chain") var fallbackChain: [FallbackStep]
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}
