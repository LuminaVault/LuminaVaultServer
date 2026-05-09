import Foundation

struct OAuthIdentityInfo: Sendable {
    let providerUserID: String
    let email: String
    let emailVerified: Bool
}

enum OAuthError: Error {
    case invalidToken
    case unverifiedEmail
    case missingClaims
    case jwksUnavailable
}

protocol OAuthProvider: Sendable {
    var name: String { get }
    /// Verifies a provider-issued id_token (signature, issuer, audience, expiry)
    /// and returns the identity info needed to link/create a User + OAuthIdentity.
    func verify(idToken: String) async throws -> OAuthIdentityInfo
}
