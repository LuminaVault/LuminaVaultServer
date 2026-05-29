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

    /// HER-300 — wraps the ordered fallback chain so Fluent persists it as a
    /// single `jsonb` value. A bare `@Field var x: [FallbackStep]` binds as a
    /// Postgres array (`jsonb[]`), which mismatches the `.json` column created
    /// in `M47_CreateUserLLMPreferences` and 500s every PUT. A non-array
    /// `Codable` wrapper binds as one `jsonb`, like `VaultFile.metadata`.
    ///
    /// Uses synthesized `Codable` (shape `{"steps":[…]}`). No legacy-shape
    /// tolerance is needed: the bare-array bug meant no PUT ever wrote a row
    /// against Postgres, so no `[…]`-shaped rows exist. A custom `init(from:)`
    /// that probed a keyed container and then fell back to a single-value
    /// container actually broke reads under Fluent's Postgres decoder, so the
    /// straightforward synthesized conformance is both simpler and correct.
    struct FallbackChain: Codable, Hashable {
        var steps: [FallbackStep]

        init(steps: [FallbackStep]) {
            self.steps = steps
        }
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
    @Field(key: "fallback_chain") var fallbackChain: FallbackChain
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}
