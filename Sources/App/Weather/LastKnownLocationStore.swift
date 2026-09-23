import Foundation
import SQLKit

/// One location fix. `place` is the device's reverse-geocoded name when it
/// sent one ("Lisbon, Portugal").
struct LocationFix: Equatable {
    let latitude: Double
    let longitude: Double
    let place: String?
    let capturedAt: Date

    /// Parses the first usable item of a `location_recent` device result —
    /// the `items` string the phone sends, `[{lat,lng,place,at}]`. Numbers
    /// may arrive as numbers or strings, and `at` may be missing.
    static func fromDeviceItems(_ items: String, now: Date = Date()) -> LocationFix? {
        guard let data = items.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        for item in array {
            guard let lat = number(item["lat"] ?? item["latitude"]),
                  let lng = number(item["lng"] ?? item["lon"] ?? item["longitude"]),
                  (-90 ... 90).contains(lat), (-180 ... 180).contains(lng)
            else { continue }
            let place = (item["place"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let at = HermesDates.parse(item["at"]) ?? now
            return LocationFix(latitude: lat, longitude: lng, place: place, capturedAt: at)
        }
        return nil
    }

    /// Parses a whole `deviceRead` tool result (`{"status":"ok","items":"[…]"}`).
    static func fromDeviceReadResult(_ result: String, now: Date = Date()) -> LocationFix? {
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["status"] as? String == "ok"
        else { return nil }
        if let items = json["items"] as? String {
            return fromDeviceItems(items, now: now)
        }
        if let items = json["items"], JSONSerialization.isValidJSONObject(items),
           let raw = try? JSONSerialization.data(withJSONObject: items),
           let string = String(data: raw, encoding: .utf8)
        {
            return fromDeviceItems(string, now: now)
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber {
            return n.doubleValue
        }
        if let s = value as? String {
            return Double(s)
        }
        return nil
    }
}

/// The last location fix per tenant, in four nullable `users` columns
/// (M136). Overwritten on every successful live read; never a history.
struct LastKnownLocationStore {
    let sql: any SQLDatabase

    func save(tenantID: UUID, fix: LocationFix) async throws {
        try await sql.raw("""
        UPDATE users
        SET last_location_lat = \(bind: fix.latitude),
            last_location_lng = \(bind: fix.longitude),
            last_location_place = \(bind: fix.place),
            last_location_at = \(bind: fix.capturedAt)
        WHERE id = \(bind: tenantID)
        """).run()
    }

    func load(tenantID: UUID) async throws -> LocationFix? {
        struct Row: Decodable {
            let last_location_lat: Double?
            let last_location_lng: Double?
            let last_location_place: String?
            let last_location_at: Date?
        }
        guard let row = try await sql.raw("""
        SELECT last_location_lat, last_location_lng, last_location_place, last_location_at
        FROM users WHERE id = \(bind: tenantID)
        """).first(decoding: Row.self),
            let lat = row.last_location_lat, let lng = row.last_location_lng
        else { return nil }
        return LocationFix(
            latitude: lat,
            longitude: lng,
            place: row.last_location_place,
            capturedAt: row.last_location_at ?? Date(timeIntervalSince1970: 0)
        )
    }

    func clear(tenantID: UUID) async throws {
        try await sql.raw("""
        UPDATE users
        SET last_location_lat = NULL, last_location_lng = NULL,
            last_location_place = NULL, last_location_at = NULL
        WHERE id = \(bind: tenantID)
        """).run()
    }
}
