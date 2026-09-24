@testable import App
import Foundation
import Logging
import Testing

/// Muse Chat stage C — the `weather_forecast` tool against a stubbed
/// Open-Meteo. No network: every HTTP call goes through `StubHTTP`.
struct WeatherForecastToolTests {
    // MARK: - Stubs

    /// Answers every GET with the queued response (or throws), and records
    /// the URLs asked for.
    actor StubHTTP: ConnectorHTTPClient {
        enum Reply {
            case ok(String)
            case status(Int)
            case failure
        }

        private var replies: [Reply]
        private(set) var urls: [URL] = []

        init(_ replies: [Reply]) {
            self.replies = replies
        }

        func get(url: URL, headers _: [String: String]) async throws -> ConnectorHTTPResponse {
            urls.append(url)
            let reply = replies.isEmpty ? .status(500) : replies.removeFirst()
            switch reply {
            case let .ok(body): return ConnectorHTTPResponse(status: 200, body: Data(body.utf8))
            case let .status(code): return ConnectorHTTPResponse(status: code, body: Data())
            case .failure: throw URLError(.notConnectedToInternet)
            }
        }
    }

    actor Cache {
        var stored: LocationFix?
        var saves = 0
        init(_ fix: LocationFix?) {
            stored = fix
        }

        func save(_ fix: LocationFix) {
            stored = fix
            saves += 1
        }
    }

    static let lisbon = LocationFix(latitude: 38.72, longitude: -9.14, place: "Lisbon", capturedAt: Date(timeIntervalSince1970: 1_790_000_000))

    /// Five dry days, then rain.
    static let forecastJSON = """
    {"latitude":38.72,"longitude":-9.14,"daily_units":{"precipitation_sum":"mm"},
     "daily":{"time":["2026-09-23","2026-09-24","2026-09-25","2026-09-26","2026-09-27","2026-09-28","2026-09-29"],
              "precipitation_sum":[0.0,0.2,0.0,0.9,0.0,6.4,1.2],
              "weathercode":[0,1,2,3,0,63,80]}}
    """

    static func tool(
        http: StubHTTP,
        live: LocationFix?,
        consent: Bool,
        cache: Cache
    ) -> WeatherForecastTool {
        WeatherForecastTool(
            forecast: OpenMeteoClient(http: http),
            liveLocation: { _ in live },
            consentAllowsLocation: { _ in consent },
            loadCached: { _ in await cache.stored },
            saveCached: { _, fix in await cache.save(fix) },
            logger: Logger(label: "test.weather")
        )
    }

    static func json(_ s: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    // MARK: - Tests

    @Test
    func `asks Open-Meteo for 7 days of daily rain and weather code`() {
        let url = OpenMeteoClient.url(latitude: 38.72, longitude: -9.14).absoluteString
        #expect(url.hasPrefix("https://api.open-meteo.com/v1/forecast?"))
        #expect(url.contains("daily=precipitation_sum,weathercode"))
        #expect(url.contains("forecast_days=7"))
        #expect(url.contains("latitude=38.7200"))
        #expect(url.contains("longitude=-9.1400"))
        #expect(url.contains("timezone=auto"))
        #expect(!url.contains("apikey"))
    }

    @Test
    func `a live fix is used, kept for later, and the dry streak is counted`() async throws {
        let http = StubHTTP([.ok(Self.forecastJSON)])
        let cache = Cache(nil)
        let out = await Self.tool(http: http, live: Self.lisbon, consent: true, cache: cache).run(tenantID: UUID())
        let json = try Self.json(out)
        #expect(json["status"] as? String == "ok")
        #expect(json["dry_streak_days"] as? Int == 5)
        let location = try #require(json["location"] as? [String: Any])
        #expect(location["source"] as? String == "device")
        #expect(location["place"] as? String == "Lisbon")
        let days = try #require(json["days"] as? [[String: Any]])
        #expect(days.count == 7)
        #expect(days[5]["summary"] as? String == "rain")
        #expect(days[5]["dry"] as? Bool == false)
        #expect(await cache.saves == 1)
        #expect(await cache.stored == Self.lisbon)
    }

    @Test
    func `phone offline falls back to the kept fix`() async throws {
        let http = StubHTTP([.ok(Self.forecastJSON)])
        let out = await Self.tool(http: http, live: nil, consent: true, cache: Cache(Self.lisbon)).run(tenantID: UUID())
        let json = try Self.json(out)
        #expect(json["status"] as? String == "ok")
        let location = try #require(json["location"] as? [String: Any])
        #expect(location["source"] as? String == "cached")
        #expect(await http.urls.count == 1)
    }

    @Test
    func `the kept fix is not used once Location access is off`() async throws {
        let http = StubHTTP([.ok(Self.forecastJSON)])
        let out = await Self.tool(http: http, live: nil, consent: false, cache: Cache(Self.lisbon)).run(tenantID: UUID())
        let json = try Self.json(out)
        #expect(json["status"] as? String == "error")
        #expect(await http.urls.isEmpty)
    }

    @Test
    func `no location at all is a tool error, not a crash`() async throws {
        let http = StubHTTP([])
        let out = await Self.tool(http: http, live: nil, consent: true, cache: Cache(nil)).run(tenantID: UUID())
        #expect(try Self.json(out)["status"] as? String == "error")
        #expect(await http.urls.isEmpty)
    }

    @Test(arguments: [WeatherForecastToolTests.StubHTTP.Reply.failure, .status(503), .ok("<html>oops</html>")])
    func `network trouble becomes a readable tool error`(reply: StubHTTP.Reply) async throws {
        let http = StubHTTP([reply])
        let out = await Self.tool(http: http, live: nil, consent: true, cache: Cache(Self.lisbon)).run(tenantID: UUID())
        let json = try Self.json(out)
        #expect(json["status"] as? String == "error")
        #expect((json["reason"] as? String)?.contains("weather service unreachable") == true)
    }

    @Test
    func `a missing rain figure is never counted as dry`() {
        let days = [
            OpenMeteoClient.Day(date: "a", precipitationMM: 0, weatherCode: 0),
            OpenMeteoClient.Day(date: "b", precipitationMM: nil, weatherCode: 0),
            OpenMeteoClient.Day(date: "c", precipitationMM: 0, weatherCode: 0),
        ]
        #expect(WeatherForecastTool.dryStreak(days) == 1)
    }

    @Test
    func `parses the renamed weather_code key too`() throws {
        let json = #"{"daily":{"time":["2026-09-23"],"precipitation_sum":[2.5],"weather_code":[61]}}"#
        let days = try OpenMeteoClient.parse(Data(json.utf8))
        #expect(days == [OpenMeteoClient.Day(date: "2026-09-23", precipitationMM: 2.5, weatherCode: 61)])
    }

    // MARK: - Device location parsing

    @Test
    func `reads the phone's location item with string or number coordinates`() throws {
        let result = #"{"status":"ok","items":"[{\"lat\":\"38.72\",\"lng\":-9.14,\"place\":\"Lisbon\",\"at\":\"2026-09-23T06:59:00Z\"}]"}"#
        let fix = try #require(LocationFix.fromDeviceReadResult(result))
        #expect(fix.latitude == 38.72)
        #expect(fix.longitude == -9.14)
        #expect(fix.place == "Lisbon")
        #expect(fix.capturedAt == ISO8601DateFormatter().date(from: "2026-09-23T06:59:00Z"))
    }

    @Test
    func `an error or an out-of-range fix yields nothing`() {
        #expect(LocationFix.fromDeviceReadResult(#"{"status":"error","reason":"device did not respond"}"#) == nil)
        #expect(LocationFix.fromDeviceReadResult(#"{"status":"ok","items":"[{\"lat\":123,\"lng\":0}]"}"#) == nil)
        #expect(LocationFix.fromDeviceReadResult(#"{"status":"ok","items":"[]"}"#) == nil)
    }
}
