import Foundation
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
    let audience: String      // your OAuth 2.0 client_id
    let issuers: Set<String> = ["https://accounts.google.com", "accounts.google.com"]
    let jwks: JWKSCache

    init(audience: String,
         jwksURL: URL = URL(string: "https://www.googleapis.com/oauth2/v3/certs")!) {
        self.audience = audience
        self.jwks = JWKSCache(url: jwksURL)
    }

    func verify(idToken: String) async throws -> OAuthIdentityInfo {
        let keys = try await jwks.current()
        let payload = try await keys.verify(idToken, as: GoogleIDClaims.self)
        guard issuers.contains(payload.iss.value) else { throw OAuthError.invalidToken }
        guard payload.aud.value.contains(audience) else { throw OAuthError.invalidToken }
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
