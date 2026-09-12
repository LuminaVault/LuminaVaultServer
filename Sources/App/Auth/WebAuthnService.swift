import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import WebAuthn

// MARK: - DTOs

/// Enrolment is authenticated, so the account is taken from the bearer
/// token, never from the body. `username` is retained only for wire
/// compatibility with shipped clients and is validated against the
/// authenticated user rather than used to look one up.
struct WebAuthnBeginRegistrationRequest: Codable {
    let username: String
    let displayName: String?
}

/// See `WebAuthnBeginRegistrationRequest` — `username` is advisory.
struct WebAuthnFinishRegistrationRequest: Codable {
    let username: String
    let credentialCreationData: RegistrationCredential
}

struct WebAuthnBeginAuthenticationRequest: Codable {
    let username: String
}

struct WebAuthnFinishAuthenticationRequest: Codable {
    let username: String
    let credential: AuthenticationCredential
}

struct WebAuthnBeginRegistrationResponse: Codable {
    let options: PublicKeyCredentialCreationOptions
}

struct WebAuthnFinishRegistrationResponse: Codable {
    let credentialID: String
}

struct WebAuthnBeginAuthenticationResponse: Codable {
    let options: PublicKeyCredentialRequestOptions
}

extension WebAuthnBeginRegistrationResponse: ResponseEncodable {}
extension WebAuthnFinishRegistrationResponse: ResponseEncodable {}
extension WebAuthnBeginAuthenticationResponse: ResponseEncodable {}

/// HER-216 — credential-management DTOs.
///
/// These mirror the wire types we ship in LuminaVaultShared once tagged
/// (>= 0.30.0). Keeping them inline here for now so the server compiles
/// before the shared package bump; replace with `LuminaVaultShared`
/// imports + delete this block after the tag lands.
struct WebAuthnCredentialSummaryDTO: Codable {
    let id: String
    let createdAt: Date
    let lastUsedAt: Date?
    let nickname: String?
}

struct WebAuthnCredentialListResponse: Codable, ResponseEncodable {
    let credentials: [WebAuthnCredentialSummaryDTO]
}

// MARK: - In-memory challenge store

//
// Single-instance only. Multi-replica deployments must move this onto a
// shared `PersistDriver` (with TTL) so challenges issued by replica A can
// be honored by replica B. Out of scope for the current single-VPS setup.

actor WebAuthnChallengeStore {
    private struct Entry {
        let challenge: [UInt8]
        let expiresAt: Date
    }

    private var registrations: [String: Entry] = [:]
    private var authentications: [String: Entry] = [:]
    private let ttl: TimeInterval = 300

    /// Registration challenges are keyed by user id, never by username.
    /// Enrolment is an authenticated ceremony, so the key has to be the thing
    /// the caller actually proved. Keying by a body-supplied username is what
    /// allowed a challenge issued for one account to be redeemed against
    /// another.
    func storeRegistration(userID: UUID, challenge: [UInt8]) {
        registrations[userID.uuidString] = Entry(
            challenge: challenge,
            expiresAt: Date().addingTimeInterval(ttl)
        )
    }

    func registration(userID: UUID) -> [UInt8]? {
        let key = userID.uuidString
        guard let e = registrations[key], e.expiresAt > Date() else {
            registrations[key] = nil
            return nil
        }
        return e.challenge
    }

    func clearRegistration(userID: UUID) {
        registrations[userID.uuidString] = nil
    }

    func storeAuthentication(username: String, challenge: [UInt8]) {
        authentications[username] = Entry(challenge: challenge, expiresAt: Date().addingTimeInterval(ttl))
    }

    func authentication(username: String) -> [UInt8]? {
        guard let e = authentications[username], e.expiresAt > Date() else {
            authentications[username] = nil
            return nil
        }
        return e.challenge
    }

    func clearAuthentication(username: String) {
        authentications[username] = nil
    }
}

// MARK: - Service

struct WebAuthnService {
    let enabled: Bool
    let relyingPartyID: String
    let relyingPartyName: String
    let relyingPartyOrigins: [String]
    let fluent: Fluent
    let repo: any AuthRepository
    let authService: any AuthService
    let logger: Logger
    private let store = WebAuthnChallengeStore()

    /// Split a configured origin list into ordered, de-duplicated entries.
    ///
    /// Comma-separated so it stays one environment variable, matching how
    /// `parseOAuthAudiences` handles multi-value OAuth audiences (PR #197).
    /// Blanks are dropped rather than preserved: an empty entry builds a
    /// manager with an empty origin, which fails every ceremony with an error
    /// that points nowhere near the trailing comma that caused it.
    static func parseOrigins(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    /// One manager per accepted origin.
    ///
    /// `WebAuthnManager.Configuration.relyingPartyOrigin` is a single `String`
    /// and the library verifies against it internally (see
    /// `WebAuthnManager.swift` — the configured origin is passed straight into
    /// the ceremony), so accepting several origins means holding several
    /// managers rather than widening a config value.
    var managers: [WebAuthnManager] {
        guard enabled, !relyingPartyID.isEmpty else { return [] }
        // Re-filter blanks here rather than trusting `parseOrigins` to have
        // done it: `relyingPartyOrigins` is a plain `[String]`, so anything
        // that builds a `WebAuthnService` directly with an empty entry (a
        // future test double, a second call site) would otherwise construct
        // a manager with an empty origin — the exact failure this property
        // must never produce.
        return relyingPartyOrigins
            .filter { !$0.isEmpty }
            .map { origin in
                WebAuthnManager(
                    configuration: .init(
                        relyingPartyID: relyingPartyID,
                        relyingPartyName: relyingPartyName,
                        relyingPartyOrigin: origin
                    )
                )
            }
    }

    /// Whether any ceremony can run at all. Distinct from `enabled`: a
    /// deployment can have the feature on and the origins unset, which is a
    /// misconfiguration rather than a deliberate opt-out.
    var isConfigured: Bool {
        !managers.isEmpty
    }

    /// True when `error` is the vendored library's client-data origin
    /// mismatch: `CollectedClientData.CollectedClientDataVerifyError
    /// .originDoesNotMatch`, thrown by `CollectedClientData.verify(...)` in
    /// `swift-webauthn` (`Sources/WebAuthn/Ceremonies/Shared/
    /// CollectedClientData.swift`) when `origin != relyingPartyOrigin`.
    ///
    /// That enum is `internal` to the `WebAuthn` module — its own test
    /// target only sees it via `@testable import` — so unlike every other
    /// ceremony failure (which surfaces as the public `WebAuthnError`), it
    /// cannot be named or `is`/`as`-cast to from here. Matching the fully
    /// qualified runtime description is the only signal that survives the
    /// module boundary. Every other error a ceremony can throw in this file
    /// (`WebAuthnError.*`, `credentialIDAlreadyExists` from the registration
    /// callback) has a distinct spelling, so this is unambiguous in
    /// practice.
    private func isOriginMismatch(_ error: any Error) -> Bool {
        String(reflecting: error) == "WebAuthn.CollectedClientData.CollectedClientDataVerifyError.originDoesNotMatch"
    }

    /// Run a ceremony against each accepted origin, returning the first
    /// success.
    ///
    /// Every attempt is a full cryptographic verification by the library, so
    /// this asks "is this credential valid for *any* origin we accept" — the
    /// same intersection semantics #197 gave OAuth audiences. It is not a
    /// weakening: a credential that verifies under one accepted origin is
    /// genuinely valid for that origin.
    ///
    /// An origin mismatch is the *expected, uninteresting* failure when
    /// probing multiple origins: a genuine client's ceremony matches exactly
    /// one manager and mismatches the rest, so most attempts "fail" this way
    /// by design. The error that escapes is therefore the first NON-mismatch
    /// error seen, falling back to the last error only if every attempt was
    /// a mismatch — otherwise a real failure on a non-last manager (a
    /// cloned-authenticator `potentialReplayAttack`, a duplicate
    /// `credentialIDAlreadyExists`, ...) would be silently replaced by the
    /// next manager's origin mismatch. With a single manager this is a
    /// no-op: whatever it throws is what escapes, mismatch or not.
    func firstVerifying<T>(
        _ ceremony: (WebAuthnManager) async throws -> T
    ) async throws -> T {
        var lastError: (any Error)?
        var firstNonOriginMismatch: (any Error)?
        for manager in managers {
            do {
                return try await ceremony(manager)
            } catch {
                lastError = error
                if firstNonOriginMismatch == nil, !isOriginMismatch(error) {
                    firstNonOriginMismatch = error
                }
            }
        }
        if let firstNonOriginMismatch {
            throw firstNonOriginMismatch
        }
        throw lastError ?? HTTPError(.serviceUnavailable, message: "webauthn disabled")
    }

    /// Unauthenticated routes: passkey *sign-in* only.
    ///
    /// Enrolment does not belong here. Binding a credential to an account is
    /// an authenticated act — see `addAuthenticatedRoutes`. These two are the
    /// sign-in ceremony itself, so they cannot require a session.
    func addRoutes(to group: RouterGroup<AppRequestContext>) {
        guard enabled else { return }
        // HER-216 — `/begin` is the canonical path; `/options` retained as
        // deprecated alias for any in-flight client still on the older
        // naming. Remove the alias once iOS ships HER-216 to TestFlight.
        group.post("/webauthn/authenticate/begin", use: beginAuthentication)
        group.post("/webauthn/authenticate/options", use: beginAuthentication)
        group.post("/webauthn/authenticate/finish", use: finishAuthentication)
    }

    /// Authenticated routes: enrol a passkey, and list / delete the ones the
    /// current user already has. Mounted under the JWT-protected group so
    /// every handler here can trust `ctx.identity`.
    ///
    /// Enrolment lives here deliberately. When these routes were mounted on
    /// the unauthenticated group and resolved the account from a body-supplied
    /// username, any caller who knew a username could bind their own
    /// authenticator to that account and then sign in as its owner.
    func addAuthenticatedRoutes(to group: RouterGroup<AppRequestContext>) {
        guard enabled else { return }
        group.post("/webauthn/register/begin", use: beginRegistration)
        group.post("/webauthn/register/options", use: beginRegistration)
        group.post("/webauthn/register/finish", use: finishRegistration)
        group.get("/webauthn/credentials", use: listCredentials)
        group.delete("/webauthn/credentials/:credentialId", use: deleteCredential)
    }

    /// The account enrolment will act on, taken from the bearer token.
    ///
    /// Call this *before* decoding the body. `jwtAuthenticator` is an
    /// `AuthenticatorMiddleware`: it hydrates `ctx.identity` but does not
    /// reject, so the handler is what enforces authentication. Decoding first
    /// means an unauthenticated caller gets their input parsed and a 400 about
    /// its shape, instead of the 401 that should end the request.
    private func enrollingUser(_ ctx: AppRequestContext) throws -> (User, UUID) {
        guard let user = ctx.identity, let userID = user.id else {
            throw HTTPError(.unauthorized, message: "missing identity")
        }
        return (user, userID)
    }

    /// The body's `username` is accepted for wire compatibility and must agree
    /// with the authenticated user; it is never used to find one.
    private func requireClaimMatches(_ claimed: String, _ user: User) throws {
        let claimed = claimed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !claimed.isEmpty, claimed.lowercased() != user.username.lowercased() {
            throw HTTPError(.forbidden, message: "username does not match the authenticated user")
        }
    }

    @Sendable
    func listCredentials(_: Request, ctx: AppRequestContext) async throws -> WebAuthnCredentialListResponse {
        guard let userID = ctx.identity?.id else {
            throw HTTPError(.unauthorized, message: "missing identity")
        }
        let rows = try await WebAuthnCredential.query(on: fluent.db(), tenantID: userID)
            .all()
        let summaries = rows.map {
            WebAuthnCredentialSummaryDTO(
                id: $0.credentialID,
                createdAt: $0.createdAt ?? Date(),
                lastUsedAt: $0.updatedAt,
                nickname: nil
            )
        }
        return WebAuthnCredentialListResponse(credentials: summaries)
    }

    @Sendable
    func deleteCredential(_: Request, ctx: AppRequestContext) async throws -> Response {
        guard let userID = ctx.identity?.id else {
            throw HTTPError(.unauthorized, message: "missing identity")
        }
        guard let credentialID = ctx.parameters.get("credentialId") else {
            throw HTTPError(.badRequest, message: "missing credentialId")
        }
        try await WebAuthnCredential.query(on: fluent.db(), tenantID: userID)
            .filter(\.$credentialID == credentialID)
            .delete()
        return Response(status: .noContent)
    }

    @Sendable
    func beginRegistration(_ req: Request, ctx: AppRequestContext) async throws -> WebAuthnBeginRegistrationResponse {
        guard let manager = managers.first else {
            throw HTTPError(.serviceUnavailable, message: "webauthn disabled")
        }
        let (user, userID) = try enrollingUser(ctx)
        let body = try await req.decode(as: WebAuthnBeginRegistrationRequest.self, context: ctx)
        try requireClaimMatches(body.username, user)

        // No anti-enumeration branch is needed: the caller is authenticated
        // and can only ever enrol for themselves, so there is no unknown
        // username to leak.
        let userEntity = PublicKeyCredentialUserEntity(
            id: Array(userID.uuidString.utf8),
            name: user.username,
            displayName: body.displayName ?? user.username
        )
        let options = manager.beginRegistration(user: userEntity)
        await store.storeRegistration(userID: userID, challenge: Array(options.challenge))
        return WebAuthnBeginRegistrationResponse(options: options)
    }

    @Sendable
    func finishRegistration(_ req: Request, ctx: AppRequestContext) async throws -> WebAuthnFinishRegistrationResponse {
        guard isConfigured else { throw HTTPError(.serviceUnavailable, message: "webauthn disabled") }
        let (user, tenantID) = try enrollingUser(ctx)
        let body = try await req.decode(as: WebAuthnFinishRegistrationRequest.self, context: ctx)
        try requireClaimMatches(body.username, user)
        guard let challenge = await store.registration(userID: tenantID) else {
            throw HTTPError(.badRequest, message: "missing or expired registration challenge")
        }
        let db = fluent.db()
        let credential = try await firstVerifying { manager in try await manager.finishRegistration(
            challenge: challenge,
            credentialCreationData: body.credentialCreationData,
            confirmCredentialIDNotRegisteredYet: { credentialID in
                let existing = try? await WebAuthnCredential.query(on: db)
                    .filter(\.$credentialID == credentialID)
                    .first()
                return existing == nil
            }
        ) }
        let row = WebAuthnCredential(
            tenantID: tenantID,
            credentialID: credential.id,
            publicKey: Data(credential.publicKey),
            signCount: credential.signCount
        )
        try await row.save(on: db)
        await store.clearRegistration(userID: tenantID)
        return WebAuthnFinishRegistrationResponse(credentialID: credential.id)
    }

    @Sendable
    func beginAuthentication(_ req: Request, ctx: AppRequestContext) async throws -> WebAuthnBeginAuthenticationResponse {
        guard let manager = managers.first else {
            throw HTTPError(.serviceUnavailable, message: "webauthn disabled")
        }
        let body = try await req.decode(as: WebAuthnBeginAuthenticationRequest.self, context: ctx)
        // Anti-enumeration: emit options even for unknown usernames.
        // /finish performs the real credential lookup and returns 401 when
        // the user / credential don't exist.
        let options = manager.beginAuthentication()
        await store.storeAuthentication(username: body.username, challenge: Array(options.challenge))
        return WebAuthnBeginAuthenticationResponse(options: options)
    }

    @Sendable
    func finishAuthentication(_ req: Request, ctx: AppRequestContext) async throws -> AuthResponse {
        guard isConfigured else { throw HTTPError(.serviceUnavailable, message: "webauthn disabled") }
        let body = try await req.decode(as: WebAuthnFinishAuthenticationRequest.self, context: ctx)
        guard let challenge = await store.authentication(username: body.username) else {
            throw HTTPError(.badRequest, message: "missing or expired authentication challenge")
        }
        // /finish-authenticate: real existence check happens here. Generic
        // 401 for both "no user" and "credential mismatch" so attackers
        // can't distinguish.
        guard let user = try await repo.findUser(byUsername: body.username) else {
            throw HTTPError(.unauthorized, message: "credential not registered")
        }
        let tenantID = try user.requireID()
        let db = fluent.db()

        let credentialIDString = body.credential.id.asString()
        guard let row = try await WebAuthnCredential.query(on: db, tenantID: tenantID)
            .filter(\.$credentialID == credentialIDString)
            .first()
        else {
            throw HTTPError(.unauthorized, message: "credential not registered")
        }

        let verified = try await firstVerifying { manager in try manager.finishAuthentication(
            credential: body.credential,
            expectedChallenge: challenge,
            credentialPublicKey: Array(row.publicKey),
            credentialCurrentSignCount: UInt32(row.signCount)
        ) }
        row.signCount = Int64(verified.newSignCount)
        try await row.save(on: db)
        await store.clearAuthentication(username: body.username)
        return try await authService.issueTokens(for: user)
    }
}
