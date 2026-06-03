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
    struct Status: Sendable {
        let connected: Bool
        let needsReauth: Bool
        let accountEmail: String?
        let lastSyncedAt: Date?
    }

    enum Error: Swift.Error, Equatable {
        case notConfigured
        case sessionNotFound
        case exchangeFailed(String)
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
    private let logger: Logger
    private let now: @Sendable () -> Date

    init(
        fluent: Fluent,
        oauth: GoogleCalendarOAuthClient,
        tokenStore: CalendarTokenStore,
        syncService: CalendarSyncService,
        sessionStore: CalendarOAuthSessionStore,
        isConfigured: Bool,
        logger: Logger,
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.fluent = fluent
        self.oauth = oauth
        self.tokenStore = tokenStore
        self.syncService = syncService
        self.sessionStore = sessionStore
        self.isConfigured = isConfigured
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

    func start(tenantID: UUID) async throws -> String {
        guard isConfigured else { throw Error.notConfigured }
        let state = UUID().uuidString + "." + UUID().uuidString
        await sessionStore.put(.init(state: state, tenantID: tenantID, startedAt: now()))
        logger.info("calendar oauth start", metadata: ["tenantID": "\(tenantID)"])
        return oauth.authorizeURL(state: state)
    }

    /// Handle Google's redirect. Returns the app deep-link the controller
    /// 302s to. `error` is Google's error param when the user declined.
    func handleCallback(state: String, code: String?, error: String?) async -> String {
        if let error {
            logger.info("calendar oauth declined", metadata: ["error": "\(error)"])
            return Self.appCallbackBase + "?status=error&reason=" + Self.encode(error)
        }
        guard let session = await sessionStore.take(state: state) else {
            return Self.appCallbackBase + "?status=error&reason=session_not_found"
        }
        guard let code else {
            return Self.appCallbackBase + "?status=error&reason=missing_code"
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
            return Self.appCallbackBase + "?status=ok"
        } catch {
            logger.error("calendar oauth exchange failed", metadata: ["error": "\(error)"])
            return Self.appCallbackBase + "?status=error&reason=exchange_failed"
        }
    }

    /// Revoke + forget. Deletes tokens and purges this tenant's cached
    /// Google events (revocation hook parallels `AppleConsentController`).
    func disconnect(tenantID: UUID) async throws {
        let db = fluent.db()
        if let account = try await CalendarAccount.query(on: db, tenantID: tenantID)
            .filter(\.$provider == "google")
            .first() {
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

    private func revokeRemote(account: CalendarAccount, tenantID: UUID) async throws {
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
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }
}
