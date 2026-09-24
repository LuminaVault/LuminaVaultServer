import Foundation
import Logging

/// Muse Chat stage C — the `weather_forecast` skill tool.
///
/// Where: a live device read when the phone answers (and that fix is kept),
/// otherwise the last kept fix, so a 07:00 cron still works with the phone
/// asleep. Both paths require the tenant's Location consent — the caller's
/// `liveLocation`/`consentAllowsLocation` enforce it.
///
/// What: Open-Meteo's 7-day daily precipitation + weather code, plus the
/// length of the dry run starting today, because "tell me when it's dry for
/// five days" is the job this exists for and the model should not have to
/// count.
///
/// Every failure — no location, network down, Open-Meteo 5xx — returns a
/// `{"status":"error","reason":…}` tool result rather than throwing, so the
/// skill still produces a message ("I couldn't reach the forecast today").
struct WeatherForecastTool {
    /// A day with less than this much rain counts as dry — the usual
    /// climatological threshold, which also ignores dew-level drizzle.
    static let dryThresholdMM = 1.0

    let forecast: OpenMeteoClient
    /// Live read from the phone; nil when it is offline, times out or
    /// consent is off.
    let liveLocation: @Sendable (UUID) async -> LocationFix?
    /// Whether the tenant currently allows Location — gates the cached fix.
    let consentAllowsLocation: @Sendable (UUID) async -> Bool
    let loadCached: @Sendable (UUID) async -> LocationFix?
    let saveCached: @Sendable (UUID, LocationFix) async -> Void
    let logger: Logger

    func run(tenantID: UUID) async -> String {
        let resolved: (fix: LocationFix, source: String)
        if let live = await liveLocation(tenantID) {
            await saveCached(tenantID, live)
            resolved = (live, "device")
        } else if await consentAllowsLocation(tenantID), let cached = await loadCached(tenantID) {
            resolved = (cached, "cached")
        } else {
            return PersonalDataTools.errorJSON(
                "no location available — the phone did not answer and no earlier location is stored (Location access must be on)"
            )
        }

        let days: [OpenMeteoClient.Day]
        do {
            days = try await forecast.dailyForecast(latitude: resolved.fix.latitude, longitude: resolved.fix.longitude)
        } catch {
            logger.warning("weather_forecast fetch failed tenant=\(tenantID): \(error)")
            return PersonalDataTools.errorJSON("weather service unreachable right now; try again later")
        }
        return Self.render(days: days, fix: resolved.fix, source: resolved.source)
    }

    static func render(days: [OpenMeteoClient.Day], fix: LocationFix, source: String) -> String {
        var location: [String: Any] = [
            "lat": fix.latitude,
            "lng": fix.longitude,
            "source": source,
            "captured_at": ISO8601DateFormatter().string(from: fix.capturedAt),
        ]
        if let place = fix.place {
            location["place"] = place
        }
        let rendered: [[String: Any]] = days.map { day in
            var row: [String: Any] = [
                "date": day.date,
                "summary": OpenMeteoClient.summary(for: day.weatherCode),
                "dry": isDry(day),
            ]
            if let mm = day.precipitationMM {
                row["precipitation_mm"] = mm
            }
            if let code = day.weatherCode {
                row["weather_code"] = code
            }
            return row
        }
        return PersonalDataTools.encodeJSON([
            "status": "ok",
            "location": location,
            "days": rendered,
            "dry_streak_days": dryStreak(days),
        ])
    }

    /// Unknown precipitation is not dry — a missing number must not produce
    /// a "five dry days" alert.
    static func isDry(_ day: OpenMeteoClient.Day) -> Bool {
        guard let mm = day.precipitationMM else { return false }
        return mm < dryThresholdMM
    }

    /// Consecutive dry days starting with the first forecast day (today).
    static func dryStreak(_ days: [OpenMeteoClient.Day]) -> Int {
        var count = 0
        for day in days {
            guard isDry(day) else { break }
            count += 1
        }
        return count
    }
}
