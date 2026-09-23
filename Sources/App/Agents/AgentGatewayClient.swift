import AsyncHTTPClient
import Foundation
import Logging
import LuminaVaultShared
import NIOCore
import NIOHTTP1

/// Calls the Agents page and agent rooms make to one Hermes gateway `api_server`.
///
/// The base URL comes from `HermesEndpointResolver`, which has already run it
/// through the SSRF guard. Reads are GETs; `chat` is the one call that
/// makes the agent act, for agent rooms.
struct AgentGatewayClient: Sendable {
    let baseURL: URL
    let authHeader: String?
    let http: any HermesHTTPExecuting
    let logger: Logger

    enum Failure: Error, Equatable {
        case unreachable
        case http(UInt)
        case invalidResponse
        /// This Hermes predates the `/api/profiles/*` routes.
        case notSupported
        /// A session id or profile name that cannot be one path segment.
        case invalidID
    }

    struct Instance: Equatable {
        let hostname: String?
        let version: String?
        let profiles: [String]
        /// The profile this gateway itself runs as — the one that answers
        /// session chat.
        var activeProfile: String?
    }

    struct ChatReply: Equatable {
        let text: String
        let totalTokens: Int?
    }

    struct SessionPage: Equatable {
        /// `false` when the gateway only knows its own profile.
        let profileAware: Bool
        let sessions: [AgentSessionDTO]
    }

    static let timeout: TimeAmount = .seconds(8)
    static let chatTimeout: TimeAmount = .seconds(180)
    static let bodyCap = 4 * 1024 * 1024

    /// `GET /api/instance`. `.notSupported` on an older Hermes.
    func instance() async throws -> Instance {
        let object = try await getObject("api/instance", notFoundIsUnsupported: true)
        return Instance(
            hostname: object["hostname"] as? String,
            version: object["version"] as? String,
            profiles: (object["profiles"] as? [String]) ?? [],
            activeProfile: object["profile"] as? String
        )
    }

    /// One agent turn in a named session, creating the session first if it
    /// does not exist. Runs as the gateway's own profile. A turn can use
    /// tools, so the timeout is long.
    func chat(sessionID: String, title: String, systemMessage: String, message: String) async throws -> ChatReply {
        let id = try Self.pathSegment(sessionID)
        let created = try await send(
            .POST, "api/sessions", json: ["id": sessionID, "title": title], timeout: Self.timeout
        )
        // 409: the session is already there from an earlier turn.
        guard created.isSuccess || created.status == 409 else { throw Failure.http(created.status) }

        let response = try await send(
            .POST, "api/sessions/\(id)/chat",
            json: ["message": message, "system_message": systemMessage],
            timeout: Self.chatTimeout
        )
        guard response.isSuccess else { throw Failure.http(response.status) }
        guard let object = response.jsonObject(),
              let text = (object["message"] as? [String: Any])?["content"] as? String
        else { throw Failure.invalidResponse }
        let usage = object["usage"] as? [String: Any]
        let total = (usage?["total_tokens"] as? Int)
            ?? ((usage?["input_tokens"] as? Int).flatMap { input in (usage?["output_tokens"] as? Int).map { input + $0 } })
        return ChatReply(text: text, totalTokens: total)
    }

    /// Connected platforms from `GET /health/detailed`. Empty when the
    /// gateway does not say; never fails the instance card.
    func connectedPlatforms() async -> [String] {
        guard let object = try? await getObject("health/detailed", notFoundIsUnsupported: false),
              let platforms = object["platforms"] as? [String: Any]
        else { return [] }
        return platforms.compactMap { name, value in
            let state = (value as? [String: Any])?["state"] as? String
            return state == nil || state == "connected" ? name : nil
        }.sorted()
    }

    /// Sessions from every profile, falling back to the single-profile
    /// `/api/sessions` on a Hermes without `/api/profiles/sessions`.
    func sessions(instanceID: String, profile: String?, source: String?, limit: Int) async throws -> SessionPage {
        var query = [("limit", String(limit))]
        if let source {
            query.append(("source", source))
        }
        do {
            var profileQuery = query
            if let profile {
                profileQuery.append(("profile", profile))
            }
            let object = try await getObject("api/profiles/sessions", query: profileQuery, notFoundIsUnsupported: true)
            return SessionPage(profileAware: true, sessions: Self.parseSessions(object, instanceID: instanceID))
        } catch Failure.notSupported {
            let object = try await getObject("api/sessions", query: query, notFoundIsUnsupported: false)
            return SessionPage(profileAware: false, sessions: Self.parseSessions(object, instanceID: instanceID))
        }
    }

    /// One session's messages. `profile == nil` reads the gateway's own
    /// profile, for Hermes versions that do not report profiles.
    func messages(profile: String?, sessionID: String) async throws -> (sessionID: String, messages: [AgentMessageDTO]) {
        let id = try Self.pathSegment(sessionID)
        let path = if let profile {
            try "api/profiles/\(Self.pathSegment(profile))/sessions/\(id)/messages"
        } else {
            "api/sessions/\(id)/messages"
        }
        let object = try await getObject(path, notFoundIsUnsupported: false)
        let resolved = (object["session_id"] as? String) ?? sessionID
        let rows = (object["data"] as? [[String: Any]]) ?? []
        return (resolved, rows.map(Self.parseMessage))
    }

    // MARK: - Parsing (internal for tests)

    static func parseSessions(_ object: [String: Any], instanceID: String) -> [AgentSessionDTO] {
        let rows = (object["data"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let lastActive = date(row["last_active"]) ?? date(row["started_at"])
            let open = row["ended_at"] == nil || row["ended_at"] is NSNull
            let recent = lastActive.map { Date().timeIntervalSince($0) < 300 } ?? false
            let isActive = (row["is_active"] as? Bool) ?? (open && recent)
            return AgentSessionDTO(
                instanceID: instanceID,
                profile: row["profile"] as? String,
                id: id,
                title: (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (row["preview"] as? String),
                source: (row["source"] as? String) ?? "unknown",
                startedAt: date(row["started_at"]),
                lastActiveAt: lastActive,
                messageCount: row["message_count"] as? Int,
                isActive: isActive,
                costUSD: (row["actual_cost_usd"] as? Double) ?? (row["estimated_cost_usd"] as? Double)
            )
        }
    }

    static func parseMessage(_ row: [String: Any]) -> AgentMessageDTO {
        var toolCalls: String?
        if let calls = row["tool_calls"], !(calls is NSNull) {
            if let text = calls as? String {
                toolCalls = text
            } else if JSONSerialization.isValidJSONObject(calls),
                      let data = try? JSONSerialization.data(withJSONObject: calls)
            {
                toolCalls = String(data: data, encoding: .utf8)
            }
        }
        return AgentMessageDTO(
            role: (row["role"] as? String) ?? "unknown",
            content: row["content"] as? String,
            toolName: row["tool_name"] as? String,
            toolCalls: toolCalls,
            createdAt: date(row["timestamp"])
        )
    }

    /// Hermes stores times as Unix seconds (float).
    static func date(_ value: Any?) -> Date? {
        switch value {
        case let seconds as Double: Date(timeIntervalSince1970: seconds)
        case let seconds as Int: Date(timeIntervalSince1970: TimeInterval(seconds))
        default: nil
        }
    }

    /// A caller-supplied id or profile name, made safe as one path segment.
    /// Rejects anything that could step out of the route.
    static func pathSegment(_ raw: String) throws -> String {
        guard !raw.isEmpty, raw.count <= 256, raw != ".", raw != "..",
              !raw.contains("/"), !raw.contains("\\"),
              raw.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/", "?", "#", "%"]))
        else {
            throw Failure.invalidID
        }
        return encoded
    }

    // MARK: - Transport

    private func send(
        _ method: HTTPMethod,
        _ path: String,
        json: [String: String],
        timeout: TimeAmount
    ) async throws -> HermesHTTPResponse {
        let base = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        var request = HTTPClientRequest(url: base + path)
        request.method = method
        request.headers.add(name: "Accept", value: "application/json")
        request.headers.add(name: "Content-Type", value: "application/json")
        if let authHeader, !authHeader.isEmpty {
            request.headers.add(name: "Authorization", value: authHeader)
        }
        request.body = try .bytes(ByteBuffer(data: JSONEncoder().encode(json)))
        do {
            return try await http.execute(request, timeout: timeout, maxBodyBytes: Self.bodyCap)
        } catch {
            logger.debug("agents gateway request failed", metadata: ["path": "\(path)", "error": "\(Logger.redact(String(describing: error)))"])
            throw Failure.unreachable
        }
    }

    private func getObject(
        _ path: String,
        query: [(String, String)] = [],
        notFoundIsUnsupported: Bool
    ) async throws -> [String: Any] {
        var components = URLComponents()
        components.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.0, value: $0.1) }
        let base = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        let url = base + path + (components.percentEncodedQuery.map { "?\($0)" } ?? "")

        var request = HTTPClientRequest(url: url)
        request.method = .GET
        request.headers.add(name: "Accept", value: "application/json")
        if let authHeader, !authHeader.isEmpty {
            request.headers.add(name: "Authorization", value: authHeader)
        }
        let response: HermesHTTPResponse
        do {
            response = try await http.execute(request, timeout: Self.timeout, maxBodyBytes: Self.bodyCap)
        } catch {
            logger.debug("agents gateway request failed", metadata: ["path": "\(path)", "error": "\(Logger.redact(String(describing: error)))"])
            throw Failure.unreachable
        }
        // A missing route means an older Hermes; a known route answering 404
        // (unknown profile or session) carries an error code and is a real 404.
        if response.status == 404, notFoundIsUnsupported,
           (response.jsonObject()?["error"] as? [String: Any])?["code"] == nil
        {
            throw Failure.notSupported
        }
        guard response.isSuccess else { throw Failure.http(response.status) }
        guard let object = response.jsonObject() else { throw Failure.invalidResponse }
        return object
    }
}
