import Foundation

struct OAuthIdentityInfo {
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

/// Splits a configured client-id value into the set of audiences a token may
/// carry.
///
/// One provider has to accept more than one audience because the same product
/// ships on more than one platform: iOS verifies against its own client id and
/// the web against another. For Apple the two are necessarily different — a
/// native sign-in is audienced to the App ID, the web to a Services ID — so a
/// single value cannot cover both.
///
/// Comma-separated so it stays one environment variable.
func parseOAuthAudiences(_ raw: String) -> Set<String> {
    Set(
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    )
}

protocol OAuthProvider: Sendable {
    var name: String { get }
    /// Verifies a provider-issued id_token (signature, issuer, audience, expiry)
    /// and returns the identity info needed to link/create a User + OAuthIdentity.
    func verify(idToken: String) async throws -> OAuthIdentityInfo
}
