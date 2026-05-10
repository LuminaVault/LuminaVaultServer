import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JWTKit

private struct AppleIDClaims: JWTPayload {
    let sub: SubjectClaim
    let aud: AudienceClaim
    let iss: IssuerClaim
    let exp: ExpirationClaim
    let email: String?
    let emailVerified: BoolOrStringClaim?

    enum CodingKeys: String, CodingKey {
        case sub, aud, iss, exp, email
        case emailVerified = "email_verified"
    }

    func verify(using _: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }
}

/// Apple emits `email_verified` as either Bool or "true"/"false" string.
struct BoolOrStringClaim: Codable, Sendable {
    let value: Bool
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) { self.value = b; return }
        if let s = try? container.decode(String.self) {
            self.value = (s.lowercased() == "true")
            return
        }
        self.value = false
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

actor JWKSCache {
    private var keys: JWTKeyCollection?
    private var fetchedAt: Date?
    private let ttl: TimeInterval = 60 * 60 * 12   // 12h
    private let url: URL

    init(url: URL) { self.url = url }

    func current() async throws -> JWTKeyCollection {
        if let keys, let fetchedAt, Date().timeIntervalSince(fetchedAt) < ttl {
            return keys
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        let collection = JWTKeyCollection()
        try await collection.add(jwksJSON: String(decoding: data, as: UTF8.self))
        self.keys = collection
        self.fetchedAt = Date()
        return collection
    }
}

struct AppleOAuthProvider: OAuthProvider {
    let name = "apple"
    let audience: String          // your Apple Sign in client_id (Service ID)
    let issuer: String = "https://appleid.apple.com"
    let jwks: JWKSCache

    init(audience: String,
         jwksURL: URL = URL(string: "https://appleid.apple.com/auth/keys")!) {
        self.audience = audience
        self.jwks = JWKSCache(url: jwksURL)
    }

    func verify(idToken: String) async throws -> OAuthIdentityInfo {
        let keys = try await jwks.current()
        let payload = try await keys.verify(idToken, as: AppleIDClaims.self)
        guard payload.iss.value == issuer else { throw OAuthError.invalidToken }
        guard payload.aud.value.contains(audience) else { throw OAuthError.invalidToken }
        guard let email = payload.email, !email.isEmpty else { throw OAuthError.missingClaims }
        let verified = payload.emailVerified?.value ?? false
        guard verified else { throw OAuthError.unverifiedEmail }
        return OAuthIdentityInfo(
            providerUserID: payload.sub.value,
            email: email,
            emailVerified: verified
        )
    }
}
