import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-340 — thin Google Calendar v3 REST client. Operates on a bearer
/// access token handed over by `CalendarTokenStore` (this type never sees
/// refresh tokens). Maps Google's event JSON into source-agnostic
/// `RemoteEvent` values the sync worker upserts into `CalendarEvent`.
struct GoogleCalendarClient {
    static let base = "https://www.googleapis.com/calendar/v3"

    /// A provider event normalized for our cache. `cancelled == true` is a
    /// tombstone delta — the worker marks the local row cancelled.
    struct RemoteEvent {
        let externalID: String
        let title: String
        let notes: String?
        let location: String?
        let startsAt: Date
        let endsAt: Date
        let allDay: Bool
        let cancelled: Bool
        let organizer: String?
        let attendees: [CalendarAttendees.Attendee]
        let recurrence: [String]
        let htmlLink: String?
        let etag: String?
        let updatedAt: Date
    }

    struct ListResult {
        let events: [RemoteEvent]
        let nextSyncToken: String?
        let nextPageToken: String?
    }

    enum Error: Swift.Error, Equatable {
        /// `410 Gone` — the stored `syncToken` is invalid; caller must do a
        /// full window re-sync.
        case syncTokenExpired
        case unauthorized
        case rateLimited
        case http(status: Int, body: String)
        case malformedResponse
    }

    let session: URLSession
    let logger: Logger

    init(session: URLSession = .shared, logger: Logger) {
        self.session = session
        self.logger = logger
    }

    /// Incremental list. Pass `syncToken` for deltas; on first sync omit it
    /// and bound the window with `timeMin`/`timeMax`. Google forbids mixing
    /// `syncToken` with time bounds, so the worker passes one or the other.
    func listEvents(
        accessToken: String,
        calendarID: String = "primary",
        syncToken: String?,
        timeMin: Date?,
        timeMax: Date?,
        pageToken: String?
    ) async throws -> ListResult {
        let encodedCal = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        var comps = URLComponents(string: "\(Self.base)/calendars/\(encodedCal)/events")!
        var items: [URLQueryItem] = [
            .init(name: "singleEvents", value: "true"),
            .init(name: "showDeleted", value: "true"),
            .init(name: "maxResults", value: "250"),
        ]
        if let syncToken {
            items.append(.init(name: "syncToken", value: syncToken))
        } else {
            if let timeMin {
                items.append(.init(name: "timeMin", value: Self.rfc3339(timeMin)))
            }
            if let timeMax {
                items.append(.init(name: "timeMax", value: Self.rfc3339(timeMax)))
            }
            items.append(.init(name: "orderBy", value: "startTime"))
        }
        if let pageToken {
            items.append(.init(name: "pageToken", value: pageToken))
        }
        comps.queryItems = items

        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200 ..< 300: break
        case 401: throw Error.unauthorized
        case 410: throw Error.syncTokenExpired
        case 403, 429: throw Error.rateLimited
        default: throw Error.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.malformedResponse
        }
        let rawItems = (json["items"] as? [[String: Any]]) ?? []
        let events = rawItems.compactMap(Self.parseEvent)
        return ListResult(
            events: events,
            nextSyncToken: json["nextSyncToken"] as? String,
            nextPageToken: json["nextPageToken"] as? String
        )
    }

    /// Create an event on the user's calendar. Returns the created
    /// `RemoteEvent` (incl. `htmlLink`) for the cache + chat echo.
    func insertEvent(
        accessToken: String,
        calendarID: String = "primary",
        title: String,
        startsAt: Date,
        endsAt: Date,
        location: String?,
        notes: String?,
        attendees: [String]
    ) async throws -> RemoteEvent {
        let encodedCal = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        let url = URL(string: "\(Self.base)/calendars/\(encodedCal)/events")!
        var body: [String: Any] = [
            "summary": title,
            "start": ["dateTime": Self.rfc3339(startsAt)],
            "end": ["dateTime": Self.rfc3339(endsAt)],
        ]
        if let location {
            body["location"] = location
        }
        if let notes {
            body["description"] = notes
        }
        if !attendees.isEmpty {
            body["attendees"] = attendees.map { ["email": $0] }
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200 ..< 300: break
        case 401: throw Error.unauthorized
        case 403, 429: throw Error.rateLimited
        default: throw Error.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = Self.parseEvent(json)
        else {
            throw Error.malformedResponse
        }
        return event
    }

    // MARK: - Parsing

    private static func parseEvent(_ raw: [String: Any]) -> RemoteEvent? {
        guard let id = raw["id"] as? String else { return nil }
        let status = raw["status"] as? String
        let cancelled = status == "cancelled"

        let (start, startAllDay) = parseEndpoint(raw["start"] as? [String: Any])
        let (end, _) = parseEndpoint(raw["end"] as? [String: Any])
        // Cancelled tombstones may omit start/end; default to epoch so the
        // row can still be matched + marked cancelled.
        let startsAt = start ?? Date(timeIntervalSince1970: 0)
        let endsAt = end ?? startsAt

        let organizer = (raw["organizer"] as? [String: Any])?["email"] as? String
        let attendees = (raw["attendees"] as? [[String: Any]])?.map {
            CalendarAttendees.Attendee(
                email: $0["email"] as? String,
                displayName: $0["displayName"] as? String,
                responseStatus: $0["responseStatus"] as? String
            )
        } ?? []
        let updated = (raw["updated"] as? String).flatMap(rfc3339Date) ?? Date()

        return RemoteEvent(
            externalID: id,
            title: (raw["summary"] as? String) ?? "(no title)",
            notes: raw["description"] as? String,
            location: raw["location"] as? String,
            startsAt: startsAt,
            endsAt: endsAt,
            allDay: startAllDay,
            cancelled: cancelled,
            organizer: organizer,
            attendees: attendees,
            recurrence: (raw["recurrence"] as? [String]) ?? [],
            htmlLink: raw["htmlLink"] as? String,
            etag: raw["etag"] as? String,
            updatedAt: updated
        )
    }

    /// Google event endpoints carry either `dateTime` (RFC3339) or `date`
    /// (YYYY-MM-DD, all-day).
    private static func parseEndpoint(_ raw: [String: Any]?) -> (Date?, Bool) {
        guard let raw else { return (nil, false) }
        if let dt = raw["dateTime"] as? String {
            return (rfc3339Date(dt), false)
        }
        if let d = raw["date"] as? String {
            return (dayDate(d), true)
        }
        return (nil, false)
    }

    /// `ISO8601DateFormatter` is not `Sendable`, so it cannot be a shared
    /// static under Swift 6 strict concurrency — build a fresh instance per
    /// call (calendar sync volume makes the allocation cost negligible).
    private static func makeFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }

    private static func rfc3339(_ date: Date) -> String {
        makeFormatter(fractional: false).string(from: date)
    }

    private static func rfc3339Date(_ string: String) -> Date? {
        makeFormatter(fractional: true).date(from: string) ?? makeFormatter(fractional: false).date(from: string)
    }

    private static func dayDate(_ string: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: string)
    }
}
