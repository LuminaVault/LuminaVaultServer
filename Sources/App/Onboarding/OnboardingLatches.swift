import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// Server-side latching of the guided-start completion flags.
///
/// `docs/guided-start.md` makes the server the single authority on guided
/// onboarding progress: a client must never PATCH `firstCaptureCompleted`,
/// `firstKBCompileCompleted` or `firstQueryCompleted` itself, because a
/// client's idea of "saved" is not the server's — iOS queues captures
/// offline and drains them much later. So the real work latches the flag as
/// a side effect, and the client only polls `GET /v1/onboarding`.
///
/// Every method here is **best effort**. Latching is bookkeeping for a
/// progress card; it must never turn a successful upload, compile or chat
/// turn into a failed request. Errors are swallowed and logged.
struct OnboardingLatches: Sendable {
    /// The three flags the server owns. Named for the step they complete,
    /// not for the caller, so a second capture surface latches the same one.
    enum Latch: String, Sendable {
        case firstCapture
        case firstMemoryCompile
        case firstQuery
    }

    let fluent: Fluent
    let logger: Logger

    /// Idempotently flips `latch` for `tenantID` and stamps its `…At`.
    /// A no-op when the flag is already set. Creates the onboarding row if
    /// the user has never hit `GET /v1/onboarding` (a capture can be the
    /// very first thing a fresh account does).
    func latch(_ latch: Latch, tenantID: UUID) async {
        do {
            let db = fluent.db()
            let row = try await loadOrCreate(tenantID: tenantID, on: db)
            let now = Date()
            switch latch {
            case .firstCapture:
                guard !row.firstCaptureCompleted else { return }
                row.firstCaptureCompleted = true
                row.firstCaptureCompletedAt = now
            case .firstMemoryCompile:
                guard !row.firstMemoryCompileCompleted || !row.firstKBCompileCompleted else { return }
                // HER-240 / spec ticket #2 — `memory_compile` is the
                // source of truth the DTO reads; the legacy `kb_compile`
                // pair is dual-written for one milestone so a rollback
                // still sees fresh state. `PATCH /v1/onboarding` does the
                // same thing; keep the two in step.
                row.firstMemoryCompileCompleted = true
                row.firstMemoryCompileCompletedAt = row.firstMemoryCompileCompletedAt ?? now
                row.firstKBCompileCompleted = true
                row.firstKBCompileCompletedAt = row.firstKBCompileCompletedAt ?? now
            case .firstQuery:
                guard !row.firstQueryCompleted else { return }
                row.firstQueryCompleted = true
                row.firstQueryCompletedAt = now
            }
            try await row.save(on: db)
        } catch {
            // Deliberately terminal: the caller's real work already
            // succeeded and must not be rolled back over a progress flag.
            logger.warning("onboarding latch \(latch.rawValue) failed tenant=\(tenantID) error=\(error)")
        }
    }

    private func loadOrCreate(tenantID: UUID, on db: any Database) async throws -> OnboardingState {
        if let existing = try await OnboardingState.query(on: db, tenantID: tenantID).first() {
            return existing
        }
        let row = OnboardingState(tenantID: tenantID, signupCompleted: true)
        try await row.save(on: db)
        return row
    }
}
