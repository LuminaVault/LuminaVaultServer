import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-340 — low-level Google OAuth token-endpoint calls for the Calendar
/// integration. Uses a **Web** OAuth client (client id + secret) so the
/// authorization-code exchange yields an offline refresh token; the
/// redirect target is the server's HTTPS callback (Web clients reject
/// custom-scheme redirects), and the server hands back to the app via the
/// `luminavault://` scheme afterwards.
///
/// Stateless — `CalendarTokenStore` owns persistence + refresh scheduling.
struct GoogleCalendarOAuthClient {
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    static let authorizeEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"

    /// Scope granted in Phase 1: read+write events + account identity.
    static let scope = "https://www.googleapis.com/auth/calendar.events openid email"

    /// Muse Chat stage C — Gmail metadata read, requested incrementally on the
    /// same client behind "Connect Gmail". A Google *restricted* scope: until
    /// the OAuth app passes Google's restricted-scope verification only test
    /// users listed on the consent screen can grant it.
    static let gmailReadonlyScope = "https://www.googleapis.com/auth/gmail.readonly"
    static let calendarEventsScope = "https://www.googleapis.com/auth/calendar.events"
    /// What "Connect Gmail" asks for. `include_granted_scopes=true` folds in
    /// whatever the account already granted (Calendar), so the returned
    /// token — and the stored `scope` — covers both.
    static let gmailConnectScope = "\(gmailReadonlyScope) openid email"

    /// Whether a space-separated OAuth `scope` string includes `wanted`.
    /// Also accepts the broader full-access scopes that imply it.
    static func grants(_ scopeString: String?, _ wanted: String) -> Bool {
        guard let scopeString else { return false }
        let granted = Set(scopeString.split(separator: " ").map(String.init))
        if granted.contains(wanted) { return true }
        switch wanted {
        case gmailReadonlyScope:
            return granted.contains("https://mail.google.com/")
                || granted.contains("https://www.googleapis.com/auth/gmail.modify")
        case calendarEventsScope:
            return granted.contains("https://www.googleapis.com/auth/calendar")
        default:
            return false
        }
    }

    /// `scopeString` without `removed`, order kept.
    static func removing(_ removed: String, from scopeString: String) -> String {
        scopeString.split(separator: " ").map(String.init).filter { $0 != removed }.joined(separator: " ")
    }

    struct TokenResponse {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        let scope: String?
        let idToken: String?
    }

    enum Error: Swift.Error, Equatable {
        /// Refresh token rejected (revoked externally / expired) — caller
        /// flips the account to `needs_reauth`.
        case refreshRejected
        case http(status: Int, body: String)
        case malformedResponse
    }

    let clientID: String
    let clientSecret: String
    let redirectURI: String
    let session: URLSession
    let logger: Logger

    init(
        clientID: String,
        clientSecret: String,
        redirectURI: String,
        session: URLSession = .shared,
        logger: Logger
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.session = session
        self.logger = logger
    }

    /// Build the Google consent URL. `state` correlates the server callback
    /// back to the in-flight session. `access_type=offline` +
    /// `prompt=consent` force a refresh token on every link.
    /// `scope` defaults to the Calendar scope; "Connect Gmail" passes
    /// `gmailConnectScope`.
    func authorizeURL(state: String, scope: String = Self.scope) -> String {
        var comps = URLComponents(string: Self.authorizeEndpoint)!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "include_granted_scopes", value: "true"),
            .init(name: "state", value: state),
        ]
        return comps.url!.absoluteString
    }

    /// Exchange an authorization code for tokens (server is the redirect
    /// target, so this runs server-side immediately on callback).
    func exchangeCode(_ code: String) async throws -> TokenResponse {
        try await postForm([
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ])
    }

    /// Trade a refresh token for a fresh access token. A `400`/`401` here
    /// means the grant is dead → `refreshRejected`.
    func refresh(refreshToken: String) async throws -> TokenResponse {
        do {
            return try await postForm([
                "refresh_token": refreshToken,
                "client_id": clientID,
                "client_secret": clientSecret,
                "grant_type": "refresh_token",
            ])
        } catch let Error.http(status, _) where status == 400 || status == 401 {
            throw Error.refreshRejected
        }
    }

    /// Best-effort revocation on disconnect. Failures are swallowed by the
    /// caller — the local row is purged regardless.
    func revoke(token: String) async throws {
        var req = URLRequest(url: Self.revokeEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formBody(["token": token])
        _ = try await session.data(for: req)
    }

    private func postForm(_ fields: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: Self.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formBody(fields)

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw Error.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            throw Error.malformedResponse
        }
        return TokenResponse(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            expiresIn: (json["expires_in"] as? Int) ?? 3600,
            scope: json["scope"] as? String,
            idToken: json["id_token"] as? String
        )
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics
        let pairs = fields.map { key, value -> String in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}
