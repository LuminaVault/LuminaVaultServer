import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

extension AppleSyncResponse: @retroactive ResponseEncodable {}

/// Apple Reminders (EventKit) selective-sync ingest.
///   POST /v1/reminders/sync — batch upsert EventKit reminder deltas.
///
/// Consent-gated on `AppleDataDomain.reminders`. Upserts by
/// `(tenant_id, external_id)` with last-writer-wins on `remote_updated_at`, so
/// overlapping delta pushes from the device are idempotent. Mirrors the
/// `HealthIngestController` ingest pattern. The persisted cache is what the
/// Hermes `reminders_list` tool reads (device-RPC stays as fallback).
struct AppleRemindersController {
    let fluent: HummingbirdFluent.Fluent
    let logger: Logger
    let maxBatchSize: Int

    init(fluent: HummingbirdFluent.Fluent, logger: Logger, maxBatchSize: Int = 1000) {
        self.fluent = fluent
        self.logger = logger
        self.maxBatchSize = maxBatchSize
    }

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/sync", use: sync)
    }

    @Sendable
    func sync(_ req: Request, ctx: AppRequestContext) async throws -> AppleSyncResponse {
        let tenantID = try ctx.requireIdentity().requireID()
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "sql unavailable")
        }

        // Consent gate — the user must have allowed the Reminders domain.
        let (allowed, _) = await AppleConsentController.isAllowed(tenantID: tenantID, domain: .reminders, sql: sql)
        guard allowed else {
            throw HTTPError(.forbidden, message: "reminders access not allowed by the user")
        }

        let body = try await req.decode(as: AppleRemindersSyncRequest.self, context: ctx)
        guard !body.reminders.isEmpty else {
            throw HTTPError(.badRequest, message: "reminders array required")
        }
        guard body.reminders.count <= maxBatchSize else {
            throw HTTPError(.contentTooLarge, message: "batch exceeds \(maxBatchSize) reminders")
        }

        var inserted = 0
        var updated = 0
        var skipped = 0

        for input in body.reminders {
            let externalID = input.externalID.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !externalID.isEmpty, !title.isEmpty else {
                skipped += 1
                continue
            }

            // Upsert by (tenant_id, external_id); last-writer-wins on
            // remote_updated_at. NULL remote_updated_at is treated as "always
            // win" (COALESCE to epoch) so first-write and clients that omit the
            // timestamp still persist; a later real timestamp will overwrite.
            let row = try await sql.raw("""
            INSERT INTO apple_reminders
              (id, tenant_id, external_id, title, notes, due_at, completed,
               completed_at, list_name, priority, remote_updated_at,
               created_at, updated_at)
            VALUES
              (gen_random_uuid(), \(bind: tenantID), \(bind: externalID),
               \(bind: title), \(bind: input.notes), \(bind: input.dueAt),
               \(bind: input.completed), \(bind: input.completedAt),
               \(bind: input.listName), \(bind: input.priority),
               \(bind: input.remoteUpdatedAt), NOW(), NOW())
            ON CONFLICT (tenant_id, external_id) DO UPDATE
              SET title = EXCLUDED.title,
                  notes = EXCLUDED.notes,
                  due_at = EXCLUDED.due_at,
                  completed = EXCLUDED.completed,
                  completed_at = EXCLUDED.completed_at,
                  list_name = EXCLUDED.list_name,
                  priority = EXCLUDED.priority,
                  remote_updated_at = EXCLUDED.remote_updated_at,
                  updated_at = NOW()
              WHERE COALESCE(EXCLUDED.remote_updated_at, 'epoch'::timestamptz)
                    >= COALESCE(apple_reminders.remote_updated_at, 'epoch'::timestamptz)
            RETURNING (xmax = 0) AS did_insert
            """).first(decoding: UpsertResult.self)

            switch row?.did_insert {
            case true: inserted += 1
            case false: updated += 1
            default: skipped += 1 // last-writer-wins rejected this stale delta
            }
        }

        logger.info("apple.reminders.sync tenant=\(tenantID) inserted=\(inserted) updated=\(updated) skipped=\(skipped)")
        return AppleSyncResponse(inserted: inserted, updated: updated, skipped: skipped)
    }

    /// `xmax = 0` distinguishes a fresh INSERT (true) from an ON CONFLICT
    /// UPDATE (false). Absent row = the WHERE clause rejected a stale delta.
    private struct UpsertResult: Decodable {
        let did_insert: Bool
    }
}
