import FluentKit
import Foundation

/// Per-user onboarding progress (1:1 with users, FK cascade).
/// Tracks which steps the user has completed so the iOS client can resume
/// onboarding after the app is killed or reinstalled.
///
/// Step semantics (once-true): each `*Completed` flag is a one-way latch.
/// Servers reject PATCH requests that try to clear a previously-set flag.
final class OnboardingState: Model, TenantModel, @unchecked Sendable {
    static let schema = "onboarding_state"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID

    @Field(key: "signup_completed") var signupCompleted: Bool
    @OptionalField(key: "signup_completed_at") var signupCompletedAt: Date?

    @Field(key: "email_verified_completed") var emailVerifiedCompleted: Bool
    @OptionalField(key: "email_verified_completed_at") var emailVerifiedCompletedAt: Date?

    @Field(key: "soul_configured_completed") var soulConfiguredCompleted: Bool
    @OptionalField(key: "soul_configured_completed_at") var soulConfiguredCompletedAt: Date?

    @Field(key: "first_capture_completed") var firstCaptureCompleted: Bool
    @OptionalField(key: "first_capture_completed_at") var firstCaptureCompletedAt: Date?

    @Field(key: "first_kb_compile_completed") var firstKBCompileCompleted: Bool
    @OptionalField(key: "first_kb_compile_completed_at") var firstKBCompileCompletedAt: Date?

    @Field(key: "first_query_completed") var firstQueryCompleted: Bool
    @OptionalField(key: "first_query_completed_at") var firstQueryCompletedAt: Date?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(tenantID: UUID, signupCompleted: Bool = false) {
        self.tenantID = tenantID
        self.signupCompleted = signupCompleted
        signupCompletedAt = signupCompleted ? Date() : nil
        emailVerifiedCompleted = false
        soulConfiguredCompleted = false
        firstCaptureCompleted = false
        firstKBCompileCompleted = false
        firstQueryCompleted = false
    }
}
