import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// HER-340 — orchestrates the Google Calendar OAuth flow (dedicated Web
/// client). Four operations the controller maps to routes:
///   * `status`     → is this tenant connected?
///   * `start`      → mint `state`, persist a session, return the consent URL
///   * `handleCallback` → exchange the code Google redirected back with,
///                        persist tokens, kick an initial sync; returns the
///                        app deep-link to close `ASWebAuthenticationSession`
///   * `disconnect` → revoke at Google + purge local tokens & cached events
///
/// Unlike `XaiOAuthService` (CLI-in-container, auth.json) this is a pure
/// server-side HTTP flow with DB-stored tokens, so it works identically for
/// managed and BYO-Hermes tenants.
actor GoogleCalendarOAuthService {
    struct Status {
        let connected: Bool
        let needsReauth: Bool
        let accountEmail: String?
        let lastSyncedAt: Date?
    }

    enum Error: Swift.Error, Equatable {
        case notConfigured
        case sessionNotFound
        case exchangeFailed(String)
        /// `returnTo` is not on an allowed web origin.
        case invalidReturn
    }

    /// App deep-link scheme the server redirects to after the callback so
    /// `ASWebAuthenticationSession` (callbackURLScheme = "luminavault")
    /// dismisses and the pane refreshes.
    static let appCallbackBase = "luminavault://oauth/google-calendar"

    private let fluent: Fluent
    private let oauth: GoogleCalendarOAuthClient
    private let tokenStore: CalendarTokenStore
    private let syncService: CalendarSyncService
    private let sessionStore: CalendarOAuthSessionStore
    private let isConfigured: Bool
    /// Origins a web client may ask to be returned to (the CORS allow-list).
    private let webReturnOrigins: Set<String>
    private let logger: Logger
    private let now: @Sendable () -> Date

    init(
        fluent: Fluent,
        oauth: GoogleCalendarOAuthClient,
        tokenStore: CalendarTokenStore,
        syncService: CalendarSyncService,
        sessionStore: CalendarOAuthSessionStore,
        isConfigured: Bool,
        webReturnOrigins: Set<String> = [],
        logger: Logger,
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.fluent = fluent
        self.oauth = oauth
        self.tokenStore = tokenStore
        self.syncService = syncService
        self.sessionStore = sessionStore
        self.isConfigured = isConfigured
        self.webReturnOrigins = webReturnOrigins
        self.logger = logger
        self.now = now
    }

    func status(tenantID: UUID) async throws -> Status {
        let account = try await CalendarAccount.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$provider == "google")
            .first()
        return Status(
            connected: account?.status == "connected",
            needsReauth: account?.status == "needs_reauth",
            accountEmail: account?.accountEmail,
            lastSyncedAt: account?.lastSyncedAt,
        )
    }

    /// `returnTo` is a web page to come back to after Google; it must be on
    /// `webReturnOrigins`, so the callback can never redirect off-site.
    func start(tenantID: UUID, returnTo: String? = nil) async throws -> String {
        guard isConfigured else { throw Error.notConfigured }
        var webReturn: String?
        if let returnTo {
            guard let valid = Self.validatedReturn(returnTo, allowedOrigins: webReturnOrigins) else {
                throw Error.invalidReturn
            }
            webReturn = valid
        }
        let state = UUID().uuidString + "." + UUID().uuidString
        await sessionStore.put(.init(state: state, tenantID: tenantID, startedAt: now(), returnTo: webReturn))
        logger.info("calendar oauth start", metadata: ["tenantID": "\(tenantID)"])
        return oauth.authorizeURL(state: state)
    }

    /// Handle Google's redirect. Returns the app deep-link the controller
    /// 302s to. `error` is Google's error param when the user declined.
    func handleCallback(state: String, code: String?, error: String?) async -> String {
        // The session says where to send the browser, so read it first —
        // even a decline has to land a web user back on the web page.
        guard let session = await sessionStore.take(state: state) else {
            return Self.redirect(base: Self.appCallbackBase, status: "error", reason: "session_not_found")
        }
        let base = session.returnTo ?? Self.appCallbackBase
        if let error {
            logger.info("calendar oauth declined", metadata: ["error": "\(error)"])
            return Self.redirect(base: base, status: "error", reason: error)
        }
        guard let code else {
            return Self.redirect(base: base, status: "error", reason: "missing_code")
        }
        do {
            let tokens = try await oauth.exchangeCode(code)
            let email = tokens.idToken.flatMap(Self.email(fromIDToken:))
            try await tokenStore.storeInitialTokens(
                tenantID: session.tenantID,
                tokens: tokens,
                accountEmail: email,
            )
            // Best-effort initial sync; failure doesn't block the connect.
            do {
                try await syncService.sync(tenantID: session.tenantID)
            } catch {
                logger.warning("calendar initial sync failed", metadata: [
                    "tenantID": "\(session.tenantID)", "error": "\(error)",
                ])
            }
            logger.info("calendar oauth connected", metadata: ["tenantID": "\(session.tenantID)"])
            return Self.redirect(base: base, status: "ok", reason: nil)
        } catch {
            logger.error("calendar oauth exchange failed", metadata: ["error": "\(error)"])
            return Self.redirect(base: base, status: "error", reason: "exchange_failed")
        }
    }

    /// `base` plus `status` (and `reason`), keeping any query `base` has.
    static func redirect(base: String, status: String, reason: String?) -> String {
        var query = "status=" + encode(status)
        if let reason {
            query += "&reason=" + encode(reason)
        }
        return base + (base.contains("?") ? "&" : "?") + query
    }

    /// `raw` when it is an absolute URL on one of `allowedOrigins`
    /// (`scheme://host[:port]`), without a fragment; otherwise `nil`.
    static func validatedReturn(_ raw: String, allowedOrigins: Set<String>) -> String? {
        guard raw.count <= 2048,
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil
        else { return nil }
        let origin = scheme + "://" + host + (components.port.map { ":\($0)" } ?? "")
        let allowed = Set(allowedOrigins.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) })
        return allowed.contains(origin) ? raw : nil
    }

    /// Revoke + forget. Deletes tokens and purges this tenant's cached
    /// Google events (revocation hook parallels `AppleConsentController`).
    func disconnect(tenantID: UUID) async throws {
        let db = fluent.db()
        if let account = try await CalendarAccount.query(on: db, tenantID: tenantID)
            .filter(\.$provider == "google")
            .first()
        {
            // Best-effort remote revoke using the refresh token.
            // (Decryption handled by token store internals is overkill here;
            // skip if we can't read it — the row is deleted regardless.)
            try? await revokeRemote(account: account, tenantID: tenantID)
            try await account.delete(on: db)
        }
        try await CalendarEvent.query(on: db, tenantID: tenantID)
            .filter(\.$source == "google")
            .delete()
    }

    private func revokeRemote(account _: CalendarAccount, tenantID: UUID) async throws {
        // The refresh token is the durable grant; revoking it invalidates
        // all derived access tokens. Token plaintext is resealed in the DB,
        // so we ask the token store for a usable access token and revoke
        // that (access-token revoke also kills the grant for our client).
        if let access = try? await tokenStore.validAccessToken(tenantID: tenantID) {
            try? await oauth.revoke(token: access)
        }
    }

    // MARK: - Helpers

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    /// Lightweight unverified decode of the `email` claim from a Google
    /// id_token. The token arrived directly from Google's token endpoint
    /// over TLS, so signature verification is unnecessary for display.
    private static func email(fromIDToken token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var b64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 {
            b64 += "="
        }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json["email"] as? String
    }
}
