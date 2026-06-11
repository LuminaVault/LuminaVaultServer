import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared

// MARK: - Server-side conformances + helpers

extension OnboardingStateDTO: @retroactive ResponseEncodable {}

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
            // HER-240 / spec ticket #2 — wire DTO field name preserved for
            // iOS compat; source-of-truth is the new memory_compile column.
            firstKBCompileCompleted: row.firstMemoryCompileCompleted,
            firstKBCompileCompletedAt: row.firstMemoryCompileCompletedAt,
            firstQueryCompleted: row.firstQueryCompleted,
            firstQueryCompletedAt: row.firstQueryCompletedAt,
            brainConfiguredCompleted: row.brainConfiguredCompleted,
            brainConfiguredCompletedAt: row.brainConfiguredCompletedAt
        )
    }
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
        try rejectFalse(body.brainConfiguredCompleted, field: "brainConfiguredCompleted")

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
        if body.firstKBCompileCompleted == true, !row.firstMemoryCompileCompleted {
            // HER-240 / spec ticket #2 — dual-write both columns so a
            // rollback to the legacy code path still sees up-to-date state.
            row.firstMemoryCompileCompleted = true
            row.firstMemoryCompileCompletedAt = now
            row.firstKBCompileCompleted = true
            row.firstKBCompileCompletedAt = now
        }
        if body.firstQueryCompleted == true, !row.firstQueryCompleted {
            row.firstQueryCompleted = true
            row.firstQueryCompletedAt = now
        }
        if body.brainConfiguredCompleted == true, !row.brainConfiguredCompleted {
            row.brainConfiguredCompleted = true
            row.brainConfiguredCompletedAt = now
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
