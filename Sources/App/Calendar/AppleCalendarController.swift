import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

// `AppleSyncResponse: ResponseEncodable` conformance is provided by
// AppleRemindersController (same module) — do not redeclare it here.

/// Apple Ecosystem Integration — Calendar (EventKit) selective-sync.
///
///   POST /v1/calendar/sync — batch-upsert EventKit event deltas
///
/// Promotes Calendar from on-demand device-RPC into a persisted server cache
/// (`calendar_events`, `source = "apple_eventkit"`) that the `calendar_query`
/// Hermes tool reads in the background. Mirrors `HealthIngestController`:
/// consent-gated, batch body, per-row validation that skips malformed rows
/// rather than failing the whole batch.
///
/// Upsert key is `(tenant_id, source, external_id)`. Last-writer-wins is
/// driven by `remote_updated_at` (EventKit `lastModifiedDate`): an incoming
/// row only overwrites an existing one when its `remote_updated_at` is newer
/// (or the existing row has none). Cancelled events are tombstoned
/// (`status = "cancelled"`), never hard-deleted.
struct AppleCalendarController {
    let fluent: HummingbirdFluent.Fluent
    let logger: Logger
    let maxBatchSize: Int

    init(fluent: HummingbirdFluent.Fluent, logger: Logger, maxBatchSize: Int = 1000) {
        self.fluent = fluent
        self.logger = logger
        self.maxBatchSize = maxBatchSize
    }

    static let source = "apple_eventkit"

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/sync", use: sync)
    }

    @Sendable
    func sync(_ req: Request, ctx: AppRequestContext) async throws -> AppleSyncResponse {
        let tenantID = try ctx.requireIdentity().requireID()
        let body = try await req.decode(as: AppleCalendarSyncRequest.self, context: ctx)
        guard !body.events.isEmpty else {
            throw HTTPError(.badRequest, message: "events array required")
        }
        guard body.events.count <= maxBatchSize else {
            throw HTTPError(.contentTooLarge, message: "batch exceeds \(maxBatchSize) events")
        }

        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "sql unavailable")
        }

        // Consent gate — the user must have allowed the Calendar domain. Read
        // access only; writes flag is irrelevant for a sync-in.
        let (allowed, _) = await AppleConsentController.isAllowed(tenantID: tenantID, domain: .calendar, sql: sql)
        guard allowed else {
            throw HTTPError(.forbidden, message: "calendar access not allowed by the user")
        }

        var inserted = 0
        var updated = 0
        var skipped = 0

        for input in body.events {
            let externalID = input.externalID.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
            // External id is the upsert key — a row without one is unaddressable.
            // Allow an empty title (cancelled / private events) but cap length.
            guard !externalID.isEmpty, externalID.count <= 512, title.count <= 1024 else {
                skipped += 1
                continue
            }
            // EventKit only marks an event "cancelled" implicitly (it disappears);
            // an explicit `status == "cancelled"` from the client tombstones.
            let status = (input.status?.trimmingCharacters(in: .whitespaces).lowercased() == "cancelled")
                ? "cancelled" : "confirmed"

            // INSERT … ON CONFLICT upsert. Last-writer-wins guard: only overwrite
            // when the incoming remote_updated_at is newer than the stored one, or
            // either side is NULL (treat NULL as "unknown, accept the delta").
            let result = try await sql.raw("""
            INSERT INTO calendar_events
                (tenant_id, source, external_id, calendar_id, title, notes, location,
                 starts_at, ends_at, all_day, status, organizer, remote_updated_at,
                 created_at, updated_at)
            VALUES
                (\(bind: tenantID), \(bind: Self.source), \(bind: externalID), \(bind: input.calendarID),
                 \(bind: title), \(bind: input.notes), \(bind: input.location),
                 \(bind: input.startsAt), \(bind: input.endsAt), \(bind: input.allDay),
                 \(bind: status), \(bind: input.organizer), COALESCE(\(bind: input.remoteUpdatedAt), NOW()),
                 NOW(), NOW())
            ON CONFLICT (tenant_id, source, external_id) DO UPDATE
                SET calendar_id = EXCLUDED.calendar_id,
                    title = EXCLUDED.title,
                    notes = EXCLUDED.notes,
                    location = EXCLUDED.location,
                    starts_at = EXCLUDED.starts_at,
                    ends_at = EXCLUDED.ends_at,
                    all_day = EXCLUDED.all_day,
                    status = EXCLUDED.status,
                    organizer = EXCLUDED.organizer,
                    remote_updated_at = EXCLUDED.remote_updated_at,
                    updated_at = NOW()
                WHERE calendar_events.remote_updated_at IS NULL
                   OR EXCLUDED.remote_updated_at IS NULL
                   OR EXCLUDED.remote_updated_at >= calendar_events.remote_updated_at
            RETURNING (xmax = 0) AS inserted
            """).first(decoding: UpsertRow.self)

            // `xmax = 0` ⇒ the row was freshly inserted; otherwise it was updated.
            // No row returned ⇒ the WHERE guard rejected a stale delta → skipped.
            if let result {
                if result.inserted {
                    inserted += 1
                } else {
                    updated += 1
                }
            } else {
                skipped += 1
            }
        }

        // Stamp the consent row's last-sync marker so the Data Access screen can
        // surface "last synced N ago" without a separate table.
        try? await sql.raw("""
        UPDATE apple_consent SET last_sync_at = NOW()
        WHERE tenant_id = \(bind: tenantID) AND domain = \(bind: AppleDataDomain.calendar.rawValue)
        """).run()

        logger.info("apple.calendar.sync tenant=\(tenantID) inserted=\(inserted) updated=\(updated) skipped=\(skipped)")
        PostHogAnalytics.capture("apple_calendar_synced", properties: ["inserted_count": inserted, "updated_count": updated, "skipped_count": skipped])
        return AppleSyncResponse(inserted: inserted, updated: updated, skipped: skipped)
    }

    private struct UpsertRow: Decodable {
        let inserted: Bool
    }
}
