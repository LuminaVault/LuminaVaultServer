import Foundation

/// Muse Chat stage C — the 7-day forecast behind the `weather_forecast` tool.
///
/// Open-Meteo is keyless and free for non-commercial volumes, so there is no
/// secret to seal and nothing to configure. We ask for exactly what a
/// "tell me when it's dry for five days" job needs: daily precipitation and
/// the WMO weather code.
struct OpenMeteoClient {
    static let endpoint = "https://api.open-meteo.com/v1/forecast"

    struct Day: Equatable {
        /// `YYYY-MM-DD` in the forecast location's own timezone.
        let date: String
        let precipitationMM: Double?
        let weatherCode: Int?
    }

    enum Error: Swift.Error, Equatable {
        case http(status: Int)
        case malformedResponse
    }

    let http: any ConnectorHTTPClient

    init(http: any ConnectorHTTPClient = URLSessionConnectorHTTPClient()) {
        self.http = http
    }

    static func url(latitude: Double, longitude: Double, days: Int = 7) -> URL {
        var comps = URLComponents(string: endpoint)!
        comps.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", latitude)),
            .init(name: "longitude", value: String(format: "%.4f", longitude)),
            .init(name: "daily", value: "precipitation_sum,weathercode"),
            .init(name: "forecast_days", value: String(days)),
            // Days in the place's own calendar, which is what "tomorrow"
            // means to the person standing there.
            .init(name: "timezone", value: "auto"),
        ]
        return comps.url!
    }

    func dailyForecast(latitude: Double, longitude: Double) async throws -> [Day] {
        let response = try await http.get(url: Self.url(latitude: latitude, longitude: longitude), headers: [:])
        guard (200 ..< 300).contains(response.status) else {
            throw Error.http(status: response.status)
        }
        return try Self.parse(response.body)
    }

    static func parse(_ data: Data) throws -> [Day] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = json["daily"] as? [String: Any],
              let dates = daily["time"] as? [String]
        else {
            throw Error.malformedResponse
        }
        let rain = daily["precipitation_sum"] as? [Any] ?? []
        // Open-Meteo renamed `weathercode` to `weather_code`; it answers the
        // old name with the old key, but read both so a rename on their side
        // costs a missing icon, not a failed tool call.
        let codes = (daily["weathercode"] ?? daily["weather_code"]) as? [Any] ?? []
        return dates.enumerated().map { index, date in
            Day(
                date: date,
                precipitationMM: index < rain.count ? (rain[index] as? NSNumber)?.doubleValue : nil,
                weatherCode: index < codes.count ? (codes[index] as? NSNumber)?.intValue : nil
            )
        }
    }

    /// Short English label for a WMO weather interpretation code.
    static func summary(for code: Int?) -> String {
        guard let code else { return "unknown" }
        switch code {
        case 0: return "clear"
        case 1, 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "fog"
        case 51, 53, 55, 56, 57: return "drizzle"
        case 61, 63, 65, 66, 67: return "rain"
        case 71, 73, 75, 77: return "snow"
        case 80, 81, 82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95, 96, 99: return "thunderstorm"
        default: return "unknown"
        }
    }
}
