import Foundation
import Hummingbird
import Logging
import WebAuthn

struct WebAuthnBeginRegistrationRequest: Codable, Sendable {
    let username: String
    let displayName: String?
}

struct WebAuthnFinishRegistrationRequest: Codable, Sendable {
    let username: String
    let credentialCreationData: RegistrationCredential
}

struct WebAuthnBeginAuthenticationRequest: Codable, Sendable {
    let username: String
}

struct WebAuthnFinishAuthenticationRequest: Codable, Sendable {
    let username: String
    let credential: AuthenticationCredential
}

struct WebAuthnBeginRegistrationResponse: Codable, Sendable {
    let options: PublicKeyCredentialCreationOptions
}

struct WebAuthnFinishRegistrationResponse: Codable, Sendable {
    let credentialID: String
}

struct WebAuthnBeginAuthenticationResponse: Codable, Sendable {
    let options: PublicKeyCredentialRequestOptions
}

struct WebAuthnFinishAuthenticationResponse: Codable, Sendable {
    let credentialID: String
    let signCount: UInt32
}

extension WebAuthnBeginRegistrationResponse: ResponseEncodable {}
extension WebAuthnFinishRegistrationResponse: ResponseEncodable {}
extension WebAuthnBeginAuthenticationResponse: ResponseEncodable {}
extension WebAuthnFinishAuthenticationResponse: ResponseEncodable {}

struct StoredCredential: Codable, Sendable {
    let credentialID: String
    let publicKey: [UInt8]
    var signCount: UInt32
}

actor WebAuthnStore {
    private var registrationChallenges: [String: [UInt8]] = [:]
    private var authenticationChallenges: [String: [UInt8]] = [:]
    private var credentials: [String: StoredCredential] = [:]

    func storeRegistrationChallenge(username: String, challenge: [UInt8]) {
        registrationChallenges[username] = challenge
    }

    func registrationChallenge(username: String) -> [UInt8]? {
        registrationChallenges[username]
    }

    func clearRegistrationChallenge(username: String) {
        registrationChallenges[username] = nil
    }

    func storeAuthenticationChallenge(username: String, challenge: [UInt8]) {
        authenticationChallenges[username] = challenge
    }

    func authenticationChallenge(username: String) -> [UInt8]? {
        authenticationChallenges[username]
    }

    func clearAuthenticationChallenge(username: String) {
        authenticationChallenges[username] = nil
    }

    func credential(username: String) -> StoredCredential? {
        credentials[username]
    }

    func saveCredential(username: String, credential: StoredCredential) {
        credentials[username] = credential
    }
}

struct WebAuthnService: Sendable {
    let enabled: Bool
    let relyingPartyID: String
    let relyingPartyName: String
    let relyingPartyOrigin: String
    let logger: Logger
    private let store = WebAuthnStore()

    private var manager: WebAuthnManager? {
        guard enabled, !relyingPartyID.isEmpty, !relyingPartyOrigin.isEmpty else { return nil }
        return WebAuthnManager(
            configuration: .init(
                relyingPartyID: relyingPartyID,
                relyingPartyName: relyingPartyName,
                relyingPartyOrigin: relyingPartyOrigin
            )
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
        let userEntity = PublicKeyCredentialUserEntity(
            id: [UInt8](body.username.utf8),
            name: body.username,
            displayName: body.displayName ?? body.username
        )
        let options = manager.beginRegistration(user: userEntity)
        await store.storeRegistrationChallenge(username: body.username, challenge: Array(options.challenge))
        return WebAuthnBeginRegistrationResponse(options: options)
    }

    @Sendable
    func finishRegistration(_ req: Request, ctx: AppRequestContext) async throws -> WebAuthnFinishRegistrationResponse {
        guard let manager else { throw HTTPError(.serviceUnavailable, message: "webauthn disabled") }
        let body = try await req.decode(as: WebAuthnFinishRegistrationRequest.self, context: ctx)
        guard let challenge = await store.registrationChallenge(username: body.username) else {
            throw HTTPError(.badRequest, message: "missing registration challenge")
        }
        let credential = try await manager.finishRegistration(
            challenge: challenge,
            credentialCreationData: body.credentialCreationData,
            confirmCredentialIDNotRegisteredYet: { [store] credentialID in
                let existing = await store.credential(username: body.username)
                return existing == nil || existing?.credentialID != credentialID
            }
        )
        await store.saveCredential(
            username: body.username,
            credential: StoredCredential(
                credentialID: credential.id,
                publicKey: credential.publicKey,
                signCount: credential.signCount
            )
        )
        await store.clearRegistrationChallenge(username: body.username)
        return WebAuthnFinishRegistrationResponse(credentialID: credential.id)
    }

    @Sendable
    func beginAuthentication(_ req: Request, ctx: AppRequestContext) async throws -> WebAuthnBeginAuthenticationResponse {
        guard let manager else { throw HTTPError(.serviceUnavailable, message: "webauthn disabled") }
        let body = try await req.decode(as: WebAuthnBeginAuthenticationRequest.self, context: ctx)
        let options = manager.beginAuthentication()
        await store.storeAuthenticationChallenge(username: body.username, challenge: Array(options.challenge))
        return WebAuthnBeginAuthenticationResponse(options: options)
    }

    @Sendable
    func finishAuthentication(_ req: Request, ctx: AppRequestContext) async throws -> WebAuthnFinishAuthenticationResponse {
        guard let manager else { throw HTTPError(.serviceUnavailable, message: "webauthn disabled") }
        let body = try await req.decode(as: WebAuthnFinishAuthenticationRequest.self, context: ctx)
        guard let challenge = await store.authenticationChallenge(username: body.username),
              let credential = await store.credential(username: body.username)
        else {
            throw HTTPError(.badRequest, message: "missing authentication challenge")
        }
        let verified = try manager.finishAuthentication(
            credential: body.credential,
            expectedChallenge: challenge,
            credentialPublicKey: credential.publicKey,
            credentialCurrentSignCount: credential.signCount
        )
        await store.saveCredential(
            username: body.username,
            credential: StoredCredential(
                credentialID: credential.credentialID,
                publicKey: credential.publicKey,
                signCount: verified.newSignCount
            )
        )
        await store.clearAuthenticationChallenge(username: body.username)
        return WebAuthnFinishAuthenticationResponse(credentialID: credential.credentialID, signCount: verified.newSignCount)
    }
}