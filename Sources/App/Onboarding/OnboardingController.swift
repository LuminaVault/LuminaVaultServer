import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared

// MARK: - Server-side conformances + helpers

extension OnboardingStateDTO: ResponseEncodable {}

/// Server-only helper to create an OnboardingStateDTO from a Fluent row.
extension OnboardingStateDTO {
    static func fromRow(_ row: OnboardingState) -> OnboardingStateDTO {
        OnboardingStateDTO(
            signupCompleted: row.signupCompleted,
            signupCompletedAt: row.signupCompletedAt,
            emailVerifiedCompleted: row.emailVerifiedCompleted,
            emailVerifiedCompletedAt: row.emailVerifiedCompletedAt,
            soulConfiguredCompleted: row.soulConfiguredCompleted,
            soulConfiguredCompletedAt: row.soulConfiguredCompletedAt,
            firstCaptureCompleted: row.firstCaptureCompleted,
            firstCaptureCompletedAt: row.firstCaptureCompletedAt,
            firstKBCompileCompleted: row.firstKBCompileCompleted,
            firstKBCompileCompletedAt: row.firstKBCompileCompletedAt,
            firstQueryCompleted: row.firstQueryCompleted,
            firstQueryCompletedAt: row.firstQueryCompletedAt,
        )
    }
}

/// PATCH body. All fields optional; only `true` values are accepted (the flag
/// is a one-way latch). A `false` value is rejected with `400`. Omitted
/// fields are left untouched.
struct OnboardingPatchRequest: Codable {
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
    func get(_: Request, ctx: AppRequestContext) async throws -> OnboardingStateDTO {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let row = try await loadOrCreate(tenantID: tenantID)
        return OnboardingStateDTO.fromRow(row)
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
        return OnboardingStateDTO.fromRow(row)
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
