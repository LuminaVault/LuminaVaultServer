import FluentKit
import SQLKit

/// `onboarding_state` table — 1:1 with `users` via UNIQUE FK CASCADE.
/// Backs `GET /v1/onboarding` and `PATCH /v1/onboarding`. See HER-93.
///
/// Each step has a paired `*_completed` bool + `*_completed_at` timestamp so
/// the iOS client can resume onboarding and so analytics can measure
/// step-to-step latency.
struct M17_CreateOnboardingState: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(OnboardingState.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("signup_completed", .bool, .required, .sql(.default(false)))
            .field("signup_completed_at", .datetime)
            .field("email_verified_completed", .bool, .required, .sql(.default(false)))
            .field("email_verified_completed_at", .datetime)
            .field("soul_configured_completed", .bool, .required, .sql(.default(false)))
            .field("soul_configured_completed_at", .datetime)
            .field("first_capture_completed", .bool, .required, .sql(.default(false)))
            .field("first_capture_completed_at", .datetime)
            .field("first_kb_compile_completed", .bool, .required, .sql(.default(false)))
            .field("first_kb_compile_completed_at", .datetime)
            .field("first_query_completed", .bool, .required, .sql(.default(false)))
            .field("first_query_completed_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "tenant_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(OnboardingState.schema).delete()
    }
}
