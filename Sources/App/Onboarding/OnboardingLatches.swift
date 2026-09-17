import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import SQLKit

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
    ///
    /// One statement, always. This sits on hot paths — every vault upload,
    /// every chat turn, and once *per URL* in the chat auto-save loop — and
    /// the overwhelmingly common case is a flag that was latched months ago,
    /// so a read-then-write would spend a round trip per request forever to
    /// learn nothing. `INSERT … ON CONFLICT (tenant_id) DO UPDATE … WHERE
    /// NOT <flag>` collapses create, flip and no-op into one round trip and
    /// makes the flip atomic:
    ///
    /// - The row is created when a capture is the very first thing a fresh
    ///   account does, without a read-then-insert race against a concurrent
    ///   `GET /v1/onboarding` — the card polls at 1s/2s/4s *while* the user
    ///   performs step 1, so that window is this feature's normal flow, and
    ///   losing it would silently drop the first latch.
    /// - Only the latch columns are written, so a concurrent `PATCH
    ///   /v1/onboarding` (a dismissal, say) cannot be clobbered by a stale
    ///   whole-row `save`.
    /// - The `WHERE NOT <flag>` on the conflict branch keeps the original
    ///   timestamp: "first" means first, not latest.
    ///
    /// Awaited rather than detached on purpose: the card polls
    /// `GET /v1/onboarding` immediately after the action completes, and a
    /// detached write would race that poll.
    func latch(_ latch: Latch, tenantID: UUID) async {
        do {
            guard let sql = fluent.db() as? any SQLDatabase else {
                logger.warning("onboarding latch \(latch.rawValue) skipped: database is not SQL")
                return
            }
            try await sql.raw(Self.upsert(latch, tenantID: tenantID, rowID: UUID())).run()
        } catch {
            // Deliberately terminal: the caller's real work already
            // succeeded and must not be rolled back over a progress flag.
            logger.warning("onboarding latch \(latch.rawValue) failed tenant=\(tenantID) error=\(error)")
        }
    }

    /// Written out per latch rather than interpolating column names, so
    /// every statement that reaches Postgres is visible in the source.
    ///
    /// New rows mirror `OnboardingController.loadOrCreate`: signup is
    /// already latched, because reaching any of these call sites means the
    /// account exists.
    private static func upsert(_ latch: Latch, tenantID: UUID, rowID: UUID) -> SQLQueryString {
        switch latch {
        case .firstCapture:
            """
            INSERT INTO onboarding_state
                (id, tenant_id, signup_completed, signup_completed_at,
                 first_capture_completed, first_capture_completed_at,
                 created_at, updated_at)
            VALUES (\(bind: rowID), \(bind: tenantID), TRUE, NOW(), TRUE, NOW(), NOW(), NOW())
            ON CONFLICT (tenant_id) DO UPDATE
               SET first_capture_completed = TRUE,
                   first_capture_completed_at = NOW(),
                   updated_at = NOW()
             WHERE NOT onboarding_state.first_capture_completed
            """
        case .firstQuery:
            """
            INSERT INTO onboarding_state
                (id, tenant_id, signup_completed, signup_completed_at,
                 first_query_completed, first_query_completed_at,
                 created_at, updated_at)
            VALUES (\(bind: rowID), \(bind: tenantID), TRUE, NOW(), TRUE, NOW(), NOW(), NOW())
            ON CONFLICT (tenant_id) DO UPDATE
               SET first_query_completed = TRUE,
                   first_query_completed_at = NOW(),
                   updated_at = NOW()
             WHERE NOT onboarding_state.first_query_completed
            """
        case .firstMemoryCompile:
            // HER-240 / spec ticket #2 — `memory_compile` is the source of
            // truth the DTO reads; the legacy `kb_compile` pair is
            // dual-written for one milestone so a rollback still sees fresh
            // state. `PATCH /v1/onboarding` does the same; keep them in step.
            //
            // The conflict branch fires when *either* pair is unset, which
            // also self-heals a row stranded by the pre-M130 bug (legacy
            // true, memory false). The `COALESCE` chain prefers a real
            // historical timestamp over `NOW()` so analytics keep the date
            // the user actually compiled on.
            """
            INSERT INTO onboarding_state
                (id, tenant_id, signup_completed, signup_completed_at,
                 first_memory_compile_completed, first_memory_compile_completed_at,
                 first_kb_compile_completed, first_kb_compile_completed_at,
                 created_at, updated_at)
            VALUES (\(bind: rowID), \(bind: tenantID), TRUE, NOW(),
                    TRUE, NOW(), TRUE, NOW(), NOW(), NOW())
            ON CONFLICT (tenant_id) DO UPDATE
               SET first_memory_compile_completed = TRUE,
                   first_memory_compile_completed_at = COALESCE(
                       onboarding_state.first_memory_compile_completed_at,
                       onboarding_state.first_kb_compile_completed_at,
                       NOW()),
                   first_kb_compile_completed = TRUE,
                   first_kb_compile_completed_at = COALESCE(
                       onboarding_state.first_kb_compile_completed_at,
                       NOW()),
                   updated_at = NOW()
             WHERE NOT (onboarding_state.first_memory_compile_completed
                        AND onboarding_state.first_kb_compile_completed)
            """
        }
    }
}
