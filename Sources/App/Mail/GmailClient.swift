import Foundation
import Logging

/// Muse Chat stage C — read-only Gmail metadata for the `mail_inbox_recent`
/// tool and the morning brief's "inbox needs a look" section.
///
/// Two calls: `users.messages.list` for the last day's inbox, then
/// `users.messages.get?format=metadata` per message for From, Subject and
/// Google's snippet. `format=metadata` never returns a body, and nothing
/// this client returns is stored — it goes straight into a tool result.
struct GmailClient {
    static let base = "https://gmail.googleapis.com/gmail/v1/users/me"
    /// Only the last day, only the inbox.
    static let recentQuery = "newer_than:1d"

    struct MessageSummary: Equatable {
        let id: String
        let from: String
        let subject: String
        let snippet: String
        let date: String?
        let unread: Bool
        let important: Bool
    }

    enum Error: Swift.Error, Equatable {
        case unauthorized
        case forbidden
        case rateLimited
        case http(status: Int)
        case malformedResponse
    }

    let http: any ConnectorHTTPClient

    init(http: any ConnectorHTTPClient = URLSessionConnectorHTTPClient()) {
        self.http = http
    }

    static func listURL(maxResults: Int) -> URL {
        var comps = URLComponents(string: "\(base)/messages")!
        comps.queryItems = [
            .init(name: "q", value: recentQuery),
            .init(name: "labelIds", value: "INBOX"),
            .init(name: "maxResults", value: String(maxResults)),
        ]
        return comps.url!
    }

    static func metadataURL(id: String) -> URL {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        var comps = URLComponents(string: "\(base)/messages/\(encoded)")!
        comps.queryItems = [
            .init(name: "format", value: "metadata"),
            .init(name: "metadataHeaders", value: "From"),
            .init(name: "metadataHeaders", value: "Subject"),
            .init(name: "metadataHeaders", value: "Date"),
        ]
        return comps.url!
    }

    func recentInbox(accessToken: String, maxResults: Int = 15) async throws -> [MessageSummary] {
        let headers = ["Authorization": "Bearer \(accessToken)", "Accept": "application/json"]
        let list = try await get(Self.listURL(maxResults: max(1, min(maxResults, 25))), headers: headers)
        guard let json = try? JSONSerialization.jsonObject(with: list) as? [String: Any] else {
            throw Error.malformedResponse
        }
        // An empty inbox omits `messages` entirely.
        let ids = (json["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        var out: [MessageSummary] = []
        for id in ids {
            let data = try await get(Self.metadataURL(id: id), headers: headers)
            if let summary = Self.parseMetadata(data) {
                out.append(summary)
            }
        }
        return out
    }

    private func get(_ url: URL, headers: [String: String]) async throws -> Data {
        let response = try await http.get(url: url, headers: headers)
        switch response.status {
        case 200 ..< 300: return response.body
        case 401: throw Error.unauthorized
        case 403: throw Error.forbidden
        case 429: throw Error.rateLimited
        default: throw Error.http(status: response.status)
        }
    }

    static func parseMetadata(_ data: Data) -> MessageSummary? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String
        else { return nil }
        let headers = ((json["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
        func header(_ name: String) -> String? {
            headers.first { ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }?["value"] as? String
        }
        let labels = Set(json["labelIds"] as? [String] ?? [])
        return MessageSummary(
            id: id,
            from: header("From") ?? "",
            subject: header("Subject") ?? "(no subject)",
            snippet: decodeEntities(json["snippet"] as? String ?? ""),
            date: header("Date"),
            unread: labels.contains("UNREAD"),
            important: labels.contains("IMPORTANT")
        )
    }

    /// Gmail snippets arrive HTML-escaped ("&#39;", "&amp;").
    static func decodeEntities(_ s: String) -> String {
        var out = s
        for (entity, char) in [("&#39;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }
}

/// Gives `mail_inbox_recent` its result: resolves the Google grant, checks it
/// includes `gmail.readonly`, fetches and renders. Never throws — a missing
/// connection or a Google error becomes a tool error the model can explain.
struct GmailInboxService {
    /// The row's granted scope string, or nil when Google isn't connected.
    let grantedScope: @Sendable (UUID) async -> String?
    let accessToken: @Sendable (UUID) async throws -> String
    let client: GmailClient
    let logger: Logger

    func recentInboxJSON(tenantID: UUID, limit: Int) async -> String {
        guard await GoogleCalendarOAuthClient.grants(grantedScope(tenantID), GoogleCalendarOAuthClient.gmailReadonlyScope) else {
            return PersonalDataTools.errorJSON("Gmail is not connected — the user can connect it in Settings")
        }
        do {
            let token = try await accessToken(tenantID)
            let messages = try await client.recentInbox(accessToken: token, maxResults: limit)
            let items: [[String: Any]] = messages.map { m in
                var row: [String: Any] = [
                    "from": m.from,
                    "subject": m.subject,
                    "snippet": m.snippet,
                    "unread": m.unread,
                    "important": m.important,
                ]
                if let date = m.date {
                    row["date"] = date
                }
                return row
            }
            return PersonalDataTools.encodeJSON(["status": "ok", "window": "last 24h", "count": items.count, "messages": items])
        } catch CalendarTokenStore.Error.needsReauth {
            return PersonalDataTools.errorJSON("Gmail needs to be reconnected in Settings")
        } catch CalendarTokenStore.Error.notConnected {
            return PersonalDataTools.errorJSON("Gmail is not connected — the user can connect it in Settings")
        } catch {
            logger.warning("mail_inbox_recent failed tenant=\(tenantID): \(error)")
            return PersonalDataTools.errorJSON("could not read Gmail right now")
        }
    }
}
