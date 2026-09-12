import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import JWTKit

private struct GoogleIDClaims: JWTPayload {
    let sub: SubjectClaim
    let aud: AudienceClaim
    let iss: IssuerClaim
    let exp: ExpirationClaim
    let email: String?
    let emailVerified: Bool?

    enum CodingKeys: String, CodingKey {
        case sub, aud, iss, exp, email
        case emailVerified = "email_verified"
    }

    func verify(using _: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }
}

struct GoogleOAuthProvider: OAuthProvider {
    let name = "google"
    /// Every OAuth 2.0 client id whose tokens this server accepts — one per
    /// platform. A token is valid when its `aud` names any of them.
    let audiences: Set<String>
    let issuers: Set<String> = ["https://accounts.google.com", "accounts.google.com"]
    let jwks: JWKSCache

    init(audiences: Set<String>,
         jwksURL: URL = URL(string: "https://www.googleapis.com/oauth2/v3/certs")!,
         session: URLSession = .shared)
    {
        self.audiences = audiences
        jwks = JWKSCache(url: jwksURL, session: session)
    }

    func verify(idToken: String) async throws -> OAuthIdentityInfo {
        let keys = try await jwks.current()
        let payload = try await keys.verify(idToken, as: GoogleIDClaims.self)
        guard issuers.contains(payload.iss.value) else { throw OAuthError.invalidToken }
        // `aud` is itself a list, so this is an intersection: the token must
        // name at least one audience this server was configured to accept.
        guard payload.aud.value.contains(where: { audiences.contains($0) }) else {
            throw OAuthError.invalidToken
        }
        guard let email = payload.email, !email.isEmpty else { throw OAuthError.missingClaims }
        let verified = payload.emailVerified ?? false
        guard verified else { throw OAuthError.unverifiedEmail }
        return OAuthIdentityInfo(
            providerUserID: payload.sub.value,
            email: email,
            emailVerified: verified
        )
    }
}
