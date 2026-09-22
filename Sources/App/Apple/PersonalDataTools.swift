import FluentKit
import Foundation
import HummingbirdFluent
import LuminaVaultShared
import SQLKit

/// Consent-gated reads and writes over the user's synced Apple / Google data
/// (Health, Calendar, Reminders), shared by every agent surface.
///
/// The server's own agent loop (`SkillRunner`) and the MCP server
/// (`MCPService`) both call these, so a Hermes on Telegram or a VPS gets
/// exactly the answers the in-app agent gets — same consent gate, same
/// cache-then-device fallback — instead of a second implementation that
/// drifts.
///
/// Every method returns tool JSON as a string: `{"status":"ok",...}` or
/// `{"status":"error","reason":...}`. `tenantID` is always the user's own id;
/// personal data never belongs to a shared vault.
struct PersonalDataTools: Sendable {
    let fluent: Fluent
    /// Where a phone write goes when the app is not connected. `nil` keeps
    /// the old behaviour: the write fails.
    var deviceQueue: DeviceCommandQueue?

    /// Daily aggregates of synced HealthKit samples, optionally one metric.
    func healthQuery(tenantID: UUID, metric: String?, days: Int?) async -> String {
        struct AggRow: Decodable { let event_type: String; let unit: String?; let day: Date; let total: Double?; let avg: Double? }
        do {
            guard let sql = fluent.db() as? any SQLDatabase else {
                return Self.errorJSON("sql unavailable")
            }
            // Consent gate — the user must have allowed the Health domain.
            let (allowed, _) = await AppleConsentController.isAllowed(tenantID: tenantID, domain: .health, sql: sql)
            guard allowed else {
                return Self.errorJSON("health access not allowed by the user")
            }
            let days = max(1, min(days ?? 30, 365))
            let rows: [AggRow] = if let metric, !metric.isEmpty {
                try await sql.raw("""
                SELECT event_type, unit, date_trunc('day', recorded_at) AS day,
                       SUM(value_numeric) AS total, AVG(value_numeric) AS avg
                FROM health_events
                WHERE tenant_id = \(bind: tenantID) AND event_type = \(bind: metric)
                  AND recorded_at >= NOW() - (\(bind: days) * INTERVAL '1 day')
                GROUP BY event_type, unit, day ORDER BY day
                """).all(decoding: AggRow.self)
            } else {
                try await sql.raw("""
                SELECT event_type, unit, date_trunc('day', recorded_at) AS day,
                       SUM(value_numeric) AS total, AVG(value_numeric) AS avg
                FROM health_events
                WHERE tenant_id = \(bind: tenantID)
                  AND recorded_at >= NOW() - (\(bind: days) * INTERVAL '1 day')
                GROUP BY event_type, unit, day ORDER BY day
                """).all(decoding: AggRow.self)
            }
            let points = rows.map { r in
                [
                    "metric": r.event_type,
                    "unit": r.unit ?? "",
                    "day": SkillRunner.fileDateStamp(r.day),
                    "total": String(format: "%.2f", r.total ?? 0),
                    "avg": String(format: "%.2f", r.avg ?? 0),
                ]
            }
            return Self.encodeJSON(["status": "ok", "days": String(days), "points": points])
        } catch {
            return Self.errorJSON("health_query failed: \(error)")
        }
    }

    /// Upcoming events from the synced cache (Apple EventKit + Google).
    /// Falls back to a live device fetch on a cache miss or DB error.
    func calendarQuery(tenantID: UUID, days: Int?) async -> String {
        struct CalRow: Decodable {
            let title: String
            let starts_at: Date
            let ends_at: Date
            let location: String?
        }
        let days = max(1, min(days ?? 7, 90))
        guard let sql = fluent.db() as? any SQLDatabase else {
            return Self.errorJSON("sql unavailable")
        }
        // Consent gate — the user must have allowed the Calendar domain.
        let (allowed, _) = await AppleConsentController.isAllowed(tenantID: tenantID, domain: .calendar, sql: sql)
        guard allowed else {
            return Self.errorJSON("calendar access not allowed by the user")
        }
        // Read the synced cache (all sources — apple_eventkit + google) for the
        // requested day window. Excludes tombstoned (cancelled) rows.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        do {
            let rows = try await sql.raw("""
            SELECT title, starts_at, ends_at, location
            FROM calendar_events
            WHERE tenant_id = \(bind: tenantID)
              AND status <> 'cancelled'
              AND starts_at >= NOW()
              AND starts_at < NOW() + (\(bind: days) * INTERVAL '1 day')
            ORDER BY starts_at ASC
            """).all(decoding: CalRow.self)
            if rows.isEmpty {
                // Cache miss — fall back to a live device round-trip so the user
                // still gets an answer before the first sync (or when offline
                // sync hasn't run). Device-RPC is the fallback, not the path.
                return await deviceRead(tenantID: tenantID, domain: .calendar, payload: ["days": String(days)])
            }
            let events = rows.map { r in
                [
                    "title": r.title,
                    "start": iso.string(from: r.starts_at),
                    "end": iso.string(from: r.ends_at),
                    "location": r.location ?? "",
                ]
            }
            return Self.encodeJSON(["status": "ok", "items": events])
        } catch {
            // On a DB error, fall back to device-RPC rather than failing the tool.
            return await deviceRead(tenantID: tenantID, domain: .calendar, payload: ["days": String(days)])
        }
    }

    /// Apple Reminders selective-sync read path. Serves the persisted
    /// `apple_reminders` cache (open/overdue items, soonest due first) the iOS
    /// client pushes via `POST /v1/reminders/sync`, so agents answer without a
    /// live device round-trip. Falls back to a fresh device_fetch when the
    /// cache is empty (device never synced, or just-installed client).
    /// Consent-gated on `.reminders`, same as the device-RPC path.
    func remindersList(tenantID: UUID) async -> String {
        guard let sql = fluent.db() as? any SQLDatabase else {
            return Self.errorJSON("sql unavailable")
        }
        let (allowed, _) = await AppleConsentController.isAllowed(tenantID: tenantID, domain: .reminders, sql: sql)
        guard allowed else { return Self.errorJSON("reminders access not allowed by the user") }

        struct Row: Decodable { let title: String; let due_at: Date?; let notes: String? }
        let rows: [Row]
        do {
            // Open (incomplete) reminders, overdue + upcoming, soonest due
            // first; NULLs (no due date) sort last. Capped to keep the tool
            // payload bounded.
            rows = try await sql.raw("""
            SELECT title, due_at, notes
            FROM apple_reminders
            WHERE tenant_id = \(bind: tenantID) AND completed = false
            ORDER BY due_at ASC NULLS LAST
            LIMIT 100
            """).all(decoding: Row.self)
        } catch {
            return Self.errorJSON("reminders_list failed: \(error)")
        }

        // Cache miss → fall back to a live device fetch.
        guard !rows.isEmpty else {
            return await deviceRead(tenantID: tenantID, domain: .reminders, payload: [:])
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let items = rows.map { row -> [String: String] in
            var item: [String: String] = ["title": row.title]
            if let due = row.due_at {
                item["due"] = iso.string(from: due)
            }
            if let notes = row.notes, !notes.isEmpty {
                item["notes"] = notes
            }
            return item
        }
        let itemsJSON = Self.encodeJSON(items)
        return Self.encodeJSON(["status": "ok", "items": itemsJSON])
    }

    func reminderCreate(tenantID: UUID, title: String, notes: String?, due: String?) async -> String {
        await deviceWrite(tenantID: tenantID, domain: .reminders, kind: .reminderCreate, payload: [
            "title": title, "notes": notes ?? "", "due": due ?? "",
        ])
    }

    func calendarCreate(tenantID: UUID, title: String, start: String, end: String?, location: String?) async -> String {
        await deviceWrite(tenantID: tenantID, domain: .calendar, kind: .calendarCreate, payload: [
            "title": title, "start": start, "end": end ?? "", "location": location ?? "",
        ])
    }

    /// Gate consent + writes, then round-trip a write command to the device
    /// via the broker and shape the result as tool JSON.
    func deviceWrite(tenantID: UUID, domain: AppleDataDomain, kind: DeviceCommandKind, payload: [String: String]) async -> String {
        guard let sql = fluent.db() as? any SQLDatabase else {
            return Self.errorJSON("sql unavailable")
        }
        let (allowed, writes) = await AppleConsentController.isAllowed(tenantID: tenantID, domain: domain, sql: sql)
        guard allowed else { return Self.errorJSON("\(domain.rawValue) access not allowed by the user") }
        guard writes else { return Self.errorJSON("\(domain.rawValue) changes not allowed by the user") }
        let command = DeviceCommand(kind: kind, domain: domain, payload: payload)
        do {
            let result = try await DeviceCommandBroker.shared.request(tenantID: tenantID, command: command)
            guard result.ok else { return Self.errorJSON(result.error ?? "device reported failure") }
            var out = ["status": "ok"]
            for (k, v) in result.payload ?? [:] {
                out[k] = v
            }
            return Self.encodeJSON(out)
        } catch {
            // The app is closed or offline. Queue the write and tell the user,
            // rather than failing something they asked for.
            if let deviceQueue, DeviceCommandQueue.queueable.contains(kind) {
                do {
                    try await deviceQueue.enqueue(tenantID: tenantID, command: command)
                    return Self.encodeJSON([
                        "status": "queued",
                        "message": "The iPhone app is not open. LuminaVault sent a notification; this happens when the app opens (within 24 hours).",
                    ])
                } catch {
                    return Self.errorJSON("device did not respond, and the write could not be queued")
                }
            }
            return Self.errorJSON("device did not respond (offline or timed out)")
        }
    }

    /// Gate consent, then round-trip a fresh read (device_fetch) to the
    /// device; returns the device's `items` JSON.
    func deviceRead(tenantID: UUID, domain: AppleDataDomain, payload: [String: String]) async -> String {
        guard let sql = fluent.db() as? any SQLDatabase else {
            return Self.errorJSON("sql unavailable")
        }
        let (allowed, _) = await AppleConsentController.isAllowed(tenantID: tenantID, domain: domain, sql: sql)
        guard allowed else { return Self.errorJSON("\(domain.rawValue) access not allowed by the user") }
        do {
            let result = try await DeviceCommandBroker.shared.request(
                tenantID: tenantID,
                command: DeviceCommand(kind: .deviceFetch, domain: domain, payload: payload)
            )
            guard result.ok else { return Self.errorJSON(result.error ?? "device reported failure") }
            return Self.encodeJSON(["status": "ok", "items": result.payload?["items"] ?? "[]"])
        } catch {
            return Self.errorJSON("device did not respond (offline or timed out)")
        }
    }

    static func encodeJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let s = String(data: data, encoding: .utf8)
        else {
            return "{\"status\":\"error\",\"reason\":\"could not encode tool result\"}"
        }
        return s
    }

    static func errorJSON(_ reason: String) -> String {
        encodeJSON(["status": "error", "reason": reason])
    }
}
