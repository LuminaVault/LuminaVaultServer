import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent

/// Wire format for the onboarding state. Every step exposes both a bool
/// (`*Completed`) and a nullable timestamp (`*CompletedAt`). Timestamps are
/// set server-side on the transition from `false` → `true`.
struct OnboardingStateDTO: Codable, ResponseEncodable, Sendable {
    let signupCompleted: Bool
    let signupCompletedAt: Date?
    let emailVerifiedCompleted: Bool
    let emailVerifiedCompletedAt: Date?
    let soulConfiguredCompleted: Bool
    let soulConfiguredCompletedAt: Date?
    let firstCaptureCompleted: Bool
    let firstCaptureCompletedAt: Date?
    let firstKBCompileCompleted: Bool
    let firstKBCompileCompletedAt: Date?
    let firstQueryCompleted: Bool
    let firstQueryCompletedAt: Date?

    init(_ row: OnboardingState) {
        self.signupCompleted = row.signupCompleted
        self.signupCompletedAt = row.signupCompletedAt
        self.emailVerifiedCompleted = row.emailVerifiedCompleted
        self.emailVerifiedCompletedAt = row.emailVerifiedCompletedAt
        self.soulConfiguredCompleted = row.soulConfiguredCompleted
        self.soulConfiguredCompletedAt = row.soulConfiguredCompletedAt
        self.firstCaptureCompleted = row.firstCaptureCompleted
        self.firstCaptureCompletedAt = row.firstCaptureCompletedAt
        self.firstKBCompileCompleted = row.firstKBCompileCompleted
        self.firstKBCompileCompletedAt = row.firstKBCompileCompletedAt
        self.firstQueryCompleted = row.firstQueryCompleted
        self.firstQueryCompletedAt = row.firstQueryCompletedAt
    }
}

/// PATCH body. All fields optional; only `true` values are accepted (the flag
/// is a one-way latch). A `false` value is rejected with `400`. Omitted
/// fields are left untouched.
struct OnboardingPatchRequest: Codable, Sendable {
    let signupCompleted: Bool?
    let emailVerifiedCompleted: Bool?
    let soulConfiguredCompleted: Bool?
    let firstCaptureCompleted: Bool?
    let firstKBCompileCompleted: Bool?
    let firstQueryCompleted: Bool?
}

struct OnboardingController {
    let fluent: Fluent

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: get)
        router.patch("", use: patch)
    }

    @Sendable
    func get(_ req: Request, ctx: AppRequestContext) async throws -> OnboardingStateDTO {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let row = try await loadOrCreate(tenantID: tenantID)
        return OnboardingStateDTO(row)
    }

    @Sendable
    func patch(_ req: Request, ctx: AppRequestContext) async throws -> OnboardingStateDTO {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let body = try await req.decode(as: OnboardingPatchRequest.self, context: ctx)

        try rejectFalse(body.signupCompleted, field: "signupCompleted")
        try rejectFalse(body.emailVerifiedCompleted, field: "emailVerifiedCompleted")
        try rejectFalse(body.soulConfiguredCompleted, field: "soulConfiguredCompleted")
        try rejectFalse(body.firstCaptureCompleted, field: "firstCaptureCompleted")
        try rejectFalse(body.firstKBCompileCompleted, field: "firstKBCompileCompleted")
        try rejectFalse(body.firstQueryCompleted, field: "firstQueryCompleted")

        let now = Date()
        let db = fluent.db()
        let row = try await loadOrCreate(tenantID: tenantID)

        if body.signupCompleted == true, !row.signupCompleted {
            row.signupCompleted = true
            row.signupCompletedAt = now
        }
        if body.emailVerifiedCompleted == true, !row.emailVerifiedCompleted {
            row.emailVerifiedCompleted = true
            row.emailVerifiedCompletedAt = now
        }
        if body.soulConfiguredCompleted == true, !row.soulConfiguredCompleted {
            row.soulConfiguredCompleted = true
            row.soulConfiguredCompletedAt = now
        }
        if body.firstCaptureCompleted == true, !row.firstCaptureCompleted {
            row.firstCaptureCompleted = true
            row.firstCaptureCompletedAt = now
        }
        if body.firstKBCompileCompleted == true, !row.firstKBCompileCompleted {
            row.firstKBCompileCompleted = true
            row.firstKBCompileCompletedAt = now
        }
        if body.firstQueryCompleted == true, !row.firstQueryCompleted {
            row.firstQueryCompleted = true
            row.firstQueryCompletedAt = now
        }

        try await row.save(on: db)
        return OnboardingStateDTO(row)
    }

    private func rejectFalse(_ value: Bool?, field: String) throws {
        if value == false {
            throw HTTPError(.badRequest, message: "\(field): onboarding flags are one-way; only true is accepted")
        }
    }

    private func loadOrCreate(tenantID: UUID) async throws -> OnboardingState {
        let db = fluent.db()
        if let existing = try await OnboardingState.query(on: db, tenantID: tenantID).first() {
            return existing
        }
        let row = OnboardingState(tenantID: tenantID, signupCompleted: true)
        try await row.save(on: db)
        return row
    }
}
