import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// HER-340 — owns the OAuth token lifecycle for connected calendar
/// accounts. Hands callers a valid access token, refreshing transparently
/// when the cached one is within `refreshSkew` of expiry.
///
/// Refresh is **single-flight per tenant**: concurrent callers (sync worker
/// + a tool call landing together) await one in-flight refresh rather than
/// each hammering Google's token endpoint. On `refreshRejected` the account
/// row is flipped to `needs_reauth` so the iOS pane prompts a reconnect and
/// the sync worker skips it.
///
/// Tokens are sealed via `SecretBox` (per-tenant key) — plaintext lives only
/// in memory for the duration of a call.
actor CalendarTokenStore {
    enum Error: Swift.Error, Equatable {
        case notConnected
        case needsReauth
        case missingRefreshToken
    }

    private let fluent: Fluent
    private let secretBox: SecretBox
    private let oauth: GoogleCalendarOAuthClient
    private let logger: Logger
    private let now: @Sendable () -> Date
    private let refreshSkew: TimeInterval = 120

    /// In-flight refresh per tenant for single-flight coalescing.
    private var inFlight: [UUID: Task<String, Swift.Error>] = [:]

    init(
        fluent: Fluent,
        secretBox: SecretBox,
        oauth: GoogleCalendarOAuthClient,
        logger: Logger,
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.fluent = fluent
        self.secretBox = secretBox
        self.oauth = oauth
        self.logger = logger
        self.now = now
    }

    /// Persist freshly-exchanged tokens after the OAuth callback. Upserts
    /// the `(tenant, provider)` account row.
    func storeInitialTokens(
        tenantID: UUID,
        provider: String = "google",
        tokens: GoogleCalendarOAuthClient.TokenResponse,
        accountEmail: String?,
    ) async throws {
        guard let refreshToken = tokens.refreshToken else {
            // No refresh token means we'd lose offline access on first
            // expiry. `prompt=consent` should always return one.
            throw Error.missingRefreshToken
        }
        let db = fluent.db()
        let account = try await CalendarAccount.query(on: db, tenantID: tenantID)
            .filter(\.$provider == provider)
            .first() ?? CalendarAccount(tenantID: tenantID, provider: provider, scope: tokens.scope ?? GoogleCalendarOAuthClient.scope)

        let refreshSealed = try secretBox.seal(refreshToken, tenantID: tenantID)
        let accessSealed = try secretBox.seal(tokens.accessToken, tenantID: tenantID)
        account.refreshCiphertext = refreshSealed.ciphertext
        account.refreshNonce = refreshSealed.nonce
        account.accessCiphertext = accessSealed.ciphertext
        account.accessNonce = accessSealed.nonce
        account.accessExpiresAt = now().addingTimeInterval(TimeInterval(tokens.expiresIn))
        account.scope = tokens.scope ?? account.scope
        account.accountEmail = accountEmail ?? account.accountEmail
        account.status = "connected"
        account.lastFailureAt = nil
        account.lastFailureCode = nil
        // Reset incremental cursor — a re-link re-syncs the window.
        account.syncToken = nil
        try await account.save(on: db)
    }

    /// Return a valid access token for `tenantID`, refreshing if needed.
    func validAccessToken(tenantID: UUID, provider: String = "google") async throws -> String {
        if let task = inFlight[tenantID] {
            return try await task.value
        }
        let db = fluent.db()
        guard let account = try await CalendarAccount.query(on: db, tenantID: tenantID)
            .filter(\.$provider == provider)
            .first() else {
            throw Error.notConnected
        }
        guard account.status == "connected" else {
            throw Error.needsReauth
        }
        // Fast path: cached access token still valid.
        if let ciphertext = account.accessCiphertext,
           let nonce = account.accessNonce,
           let expiry = account.accessExpiresAt,
           expiry.timeIntervalSince(now()) > refreshSkew {
            return try secretBox.open(.init(ciphertext: ciphertext, nonce: nonce), tenantID: tenantID)
        }
        // Slow path: refresh under single-flight.
        let task = Task<String, Swift.Error> { [secretBox, oauth, fluent, now] in
            defer { Task { await self.clearInFlight(tenantID) } }
            guard let rc = account.refreshCiphertext, let rn = account.refreshNonce else {
                throw Error.missingRefreshToken
            }
            let refreshToken = try secretBox.open(.init(ciphertext: rc, nonce: rn), tenantID: tenantID)
            do {
                let fresh = try await oauth.refresh(refreshToken: refreshToken)
                let accessSealed = try secretBox.seal(fresh.accessToken, tenantID: tenantID)
                account.accessCiphertext = accessSealed.ciphertext
                account.accessNonce = accessSealed.nonce
                account.accessExpiresAt = now().addingTimeInterval(TimeInterval(fresh.expiresIn))
                // Google may rotate the refresh token; persist if so.
                if let rotated = fresh.refreshToken {
                    let rs = try secretBox.seal(rotated, tenantID: tenantID)
                    account.refreshCiphertext = rs.ciphertext
                    account.refreshNonce = rs.nonce
                }
                try await account.save(on: fluent.db())
                return fresh.accessToken
            } catch GoogleCalendarOAuthClient.Error.refreshRejected {
                account.status = "needs_reauth"
                account.lastFailureAt = now()
                account.lastFailureCode = "refresh_rejected"
                try? await account.save(on: fluent.db())
                throw Error.needsReauth
            }
        }
        inFlight[tenantID] = task
        return try await task.value
    }

    private func clearInFlight(_ tenantID: UUID) {
        inFlight[tenantID] = nil
    }
}
