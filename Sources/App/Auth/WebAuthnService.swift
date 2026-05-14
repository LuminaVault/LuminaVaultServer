import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import WebAuthn
import LuminaVaultShared

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
    let relyingPartyOrigin: String
    let fluent: Fluent
    let repo: any AuthRepository
    let authService: any AuthService
    let logger: Logger
    private let store = WebAuthnChallengeStore()

    private var manager: WebAuthnManager? {
        guard enabled, !relyingPartyID.isEmpty, !relyingPartyOrigin.isEmpty else { return nil }
        return WebAuthnManager(
            configuration: .init(
                relyingPartyID: relyingPartyID,
                relyingPartyName: relyingPartyName,
                relyingPartyOrigin: relyingPartyOrigin,
            ),
        )
    }

    func addRoutes(to group: RouterGroup<AppRequestContext>) {
        guard enabled else { return }
        group.post("/webauthn/register/options", use: beginRegistration)
        group.post("/webauthn/register/finish", use: finishRegistration)
        group.post("/webauthn/authenticate/options", use: beginAuthentication)
        group.post("/webauthn/authenticate/finish", use: finishAuthentication)
    }

    @Sendable
    func beginRegistration(_ req: Request, ctx: AppRequestContext) async throws -> WebAuthnBeginRegistrationResponse {
        guard let manager else { throw HTTPError(.serviceUnavailable, message: "webauthn disabled") }
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
            displayName: body.displayName ?? body.username,
        )
        let options = manager.beginRegistration(user: userEntity)
        await store.storeRegistration(username: body.username, challenge: Array(options.challenge))
        return WebAuthnBeginRegistrationResponse(options: options)
    }

    @Sendable
    func finishRegistration(_ req: Request, ctx: AppRequestContext) async throws -> WebAuthnFinishRegistrationResponse {
        guard let manager else { throw HTTPError(.serviceUnavailable, message: "webauthn disabled") }
        let body = try await req.decode(as: WebAuthnFinishRegistrationRequest.self, context: ctx)
        guard let challenge = await store.registration(username: body.username) else {
            throw HTTPError(.badRequest, message: "missing or expired registration challenge")
        }
        guard let user = try await repo.findUser(byUsername: body.username) else {
            throw HTTPError(.notFound, message: "user not found")
        }
        let tenantID = try user.requireID()
        let db = fluent.db()
        let credential = try await manager.finishRegistration(
            challenge: challenge,
            credentialCreationData: body.credentialCreationData,
            confirmCredentialIDNotRegisteredYet: { credentialID in
                let existing = try? await WebAuthnCredential.query(on: db)
                    .filter(\.$credentialID == credentialID)
                    .first()
                return existing == nil
            },
        )
        let row = WebAuthnCredential(
            tenantID: tenantID,
            credentialID: credential.id,
            publicKey: Data(credential.publicKey),
            signCount: credential.signCount,
        )
        try await row.save(on: db)
        await store.clearRegistration(username: body.username)
        return WebAuthnFinishRegistrationResponse(credentialID: credential.id)
    }

    @Sendable
    func beginAuthentication(_ req: Request, ctx: AppRequestContext) async throws -> WebAuthnBeginAuthenticationResponse {
        guard let manager else { throw HTTPError(.serviceUnavailable, message: "webauthn disabled") }
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
        guard let manager else { throw HTTPError(.serviceUnavailable, message: "webauthn disabled") }
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

        let verified = try manager.finishAuthentication(
            credential: body.credential,
            expectedChallenge: challenge,
            credentialPublicKey: Array(row.publicKey),
            credentialCurrentSignCount: UInt32(row.signCount),
        )
        row.signCount = Int64(verified.newSignCount)
        try await row.save(on: db)
        await store.clearAuthentication(username: body.username)
        return try await authService.issueTokens(for: user)
    }
}
