import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared
import SQLKit

/// `GET /v1/me/learned` — what Lumina picked up about the user since `since`
/// that they have not confirmed yet. Deterministic SQL, no model call.
///
/// - **soulChanges**: proposed SOUL.md edits (`self_improvement_changes`,
///   kind `soul`, state `pending`), newest first.
/// - **memories**: preference and decision memories still `pending` or
///   `auto` (so never rejected, never already approved), newest first.
///
/// Keep / edit / forget go through the existing endpoints; this only reads.
/// The weekly push (`LearnedDigestScheduler`) builds the same digest.
struct MeLearnedService {
    let fluent: Fluent

    /// Default window: the last seven days.
    static let defaultWindow: TimeInterval = 7 * 24 * 60 * 60
    /// `since` may reach back at most this far.
    static let maxWindow: TimeInterval = 90 * 24 * 60 * 60
    /// Per-list cap.
    static let limit = 20
    static let memoryKinds: [String] = [MemoryKindDTO.preference.rawValue, MemoryKindDTO.decision.rawValue]
    static let memoryReviewStates: [String] = [MemoryReviewState.pending, MemoryReviewState.auto]

    private struct SoulRow: Decodable {
        let id: UUID
        let title: String
        let summary: String
        let created_at: Date
    }

    private struct MemoryRow: Decodable {
        let id: UUID
        let content: String
        let kind: String
        let review_state: String
        let created_at: Date
    }

    func build(tenantID: UUID, since: Date, now: Date = Date()) async throws -> LearnedDigestResponse {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for learned digest")
        }

        let soul = try await sql.raw("""
        SELECT id, title, summary, created_at
        FROM self_improvement_changes
        WHERE tenant_id = \(bind: tenantID)
          AND kind = \(bind: ImprovementChangeKind.soul.rawValue)
          AND state = \(bind: ImprovementChangeState.pending.rawValue)
          AND created_at >= \(bind: since)
          AND created_at <= \(bind: now)
        ORDER BY created_at DESC, id DESC
        LIMIT \(bind: Self.limit)
        """).all(decoding: SoulRow.self)

        let memories = try await sql.raw("""
        SELECT id, content, kind, review_state, created_at
        FROM memories
        WHERE tenant_id = \(bind: tenantID)
          AND kind IN (\(unsafeRaw: MeRecapService.sqlList(Self.memoryKinds)))
          AND review_state IN (\(unsafeRaw: MeRecapService.sqlList(Self.memoryReviewStates)))
          AND created_at >= \(bind: since)
          AND created_at <= \(bind: now)
        ORDER BY created_at DESC, id DESC
        LIMIT \(bind: Self.limit)
        """).all(decoding: MemoryRow.self)

        return LearnedDigestResponse(
            since: since,
            until: now,
            soulChanges: soul.map {
                LearnedSoulChangeDTO(id: $0.id, title: $0.title, summary: $0.summary, createdAt: $0.created_at)
            },
            memories: memories.map {
                LearnedMemoryDTO(
                    id: $0.id,
                    snippet: MemoryController.relatedSnippet($0.content),
                    kind: $0.kind,
                    reviewState: $0.review_state,
                    createdAt: $0.created_at
                )
            }
        )
    }

    // MARK: - Push copy

    /// Counts only, never content: the lock screen is not private.
    /// "Things about you" are proposed SOUL.md changes plus preferences.
    static func pushBody(for digest: LearnedDigestResponse) -> String? {
        let preferences = digest.memories.count(where: { $0.kind == MemoryKindDTO.preference.rawValue })
        let aboutYou = digest.soulChanges.count + preferences
        let decisions = digest.memories.count(where: { $0.kind == MemoryKindDTO.decision.rawValue })
        var parts: [String] = []
        if aboutYou > 0 {
            parts.append("\(aboutYou) \(aboutYou == 1 ? "thing" : "things") about you")
        }
        if decisions > 0 {
            parts.append("\(decisions) \(decisions == 1 ? "decision" : "decisions")")
        }
        guard !parts.isEmpty else { return nil }
        let pronoun = aboutYou + decisions == 1 ? "it" : "them"
        return parts.joined(separator: " and ") + " — keep, edit or forget \(pronoun)."
    }
}
