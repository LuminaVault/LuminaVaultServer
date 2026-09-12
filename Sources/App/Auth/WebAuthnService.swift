import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import WebAuthn

// MARK: - DTOs

struct WebAuthnBeginRegistrationRequest: Codable {
    let username: String
    let displayName: String?
}

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

    func storeRegistration(username: String, challenge: [UInt8]) {
        registrations[username] = Entry(challenge: challenge, expiresAt: Date().addingTimeInterval(ttl))
    }

    func registration(username: String) -> [UInt8]? {
        guard let e = registrations[username], e.expiresAt > Date() else {
            registrations[username] = nil
            return nil
        }
        return e.challenge
    }

    func clearRegistration(username: String) {
        registrations[username] = nil
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

    /// Run a ceremony against each accepted origin, returning the first
    /// success.
    ///
    /// Every attempt is a full cryptographic verification by the library, so
    /// this asks "is this credential valid for *any* origin we accept" — the
    /// same intersection semantics #197 gave OAuth audiences. It is not a
    /// weakening: a credential that verifies under one accepted origin is
    /// genuinely valid for that origin.
    ///
    /// The last error is rethrown so a genuinely bad credential still reports
    /// the library's own reason rather than a generic failure.
    func firstVerifying<T>(
        _ ceremony: (WebAuthnManager) async throws -> T
    ) async throws -> T {
        var lastError: (any Error)?
        for manager in managers {
            do {
                return try await ceremony(manager)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? HTTPError(.serviceUnavailable, message: "webauthn disabled")
    }

    func addRoutes(to group: RouterGroup<AppRequestContext>) {
        guard enabled else { return }
        // HER-216 — `/begin` is the canonical path; `/options` retained as
        // deprecated alias for any in-flight client still on the older
        // naming. Remove the alias once iOS ships HER-216 to TestFlight.
        group.post("/webauthn/register/begin", use: beginRegistration)
        group.post("/webauthn/register/options", use: beginRegistration)
        group.post("/webauthn/register/finish", use: finishRegistration)
        group.post("/webauthn/authenticate/begin", use: beginAuthentication)
        group.post("/webauthn/authenticate/options", use: beginAuthentication)
        group.post("/webauthn/authenticate/finish", use: finishAuthentication)
    }

    /// Authenticated routes: list / delete enrolled passkeys for the
    /// current user. Mounted by `AuthController` under the JWT-protected
    /// group so the `userID()` lookup is safe.
    func addAuthenticatedRoutes(to group: RouterGroup<AppRequestContext>) {
        guard enabled else { return }
        group.get("/webauthn/credentials", use: listCredentials)
        group.delete("/webauthn/credentials/:credentialId", use: deleteCredential)
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
        let body = try await req.decode(as: WebAuthnBeginRegistrationRequest.self, context: ctx)

        // Anti-enumeration: don't 404 when the username is unknown — that
        // leaks "this account exists" to scanners. Issue a syntactically
        // valid challenge anyway. The flow will fail at /finish (where the
        // attacker's `RegistrationCredential` doesn't match a real user).
        let userIDBytes: [UInt8] = if let user = try await repo.findUser(byUsername: body.username) {
            try Array(user.requireID().uuidString.utf8)
        } else {
            // Generate a deterministic-but-opaque pseudo-id so attackers
            // can't time-side-channel based on response shape.
            Array(UUID().uuidString.utf8)
        }
        let userEntity = PublicKeyCredentialUserEntity(
            id: userIDBytes,
            name: body.username,
            displayName: body.displayName ?? body.username
        )
        let options = manager.beginRegistration(user: userEntity)
        await store.storeRegistration(username: body.username, challenge: Array(options.challenge))
        return WebAuthnBeginRegistrationResponse(options: options)
    }

    @Sendable
    func finishRegistration(_ req: Request, ctx: AppRequestContext) async throws -> WebAuthnFinishRegistrationResponse {
        guard isConfigured else { throw HTTPError(.serviceUnavailable, message: "webauthn disabled") }
        let body = try await req.decode(as: WebAuthnFinishRegistrationRequest.self, context: ctx)
        guard let challenge = await store.registration(username: body.username) else {
            throw HTTPError(.badRequest, message: "missing or expired registration challenge")
        }
        guard let user = try await repo.findUser(byUsername: body.username) else {
            throw HTTPError(.notFound, message: "user not found")
        }
        let tenantID = try user.requireID()
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
        await store.clearRegistration(username: body.username)
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
