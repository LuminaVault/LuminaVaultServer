import Foundation
import JWTKit

/// Access token payload. HMAC HS256 signed.
/// `sub` carries the user UUID (== tenantID for all TenantModel queries).
/// `hpid` carries the Hermes Profile ID (string == "hermes-<username>" under
/// the current gateway), so request handlers can route to Hermes without a
/// DB round-trip. Optional for forward-compat with tokens minted before
/// the claim landed.
/// `iat` is the standard issued-at claim, used by destructive endpoints
/// (HER-92 account deletion) to gate on a "fresh re-auth" window without
/// requiring the password body on every call.
struct SessionToken: JWTPayload {
    var subject: SubjectClaim
    var expiration: ExpirationClaim
    var issuedAt: IssuedAtClaim?
    var jti: String
    var hpid: String?

    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
        case issuedAt = "iat"
        case jti
        case hpid
    }

    init(
        userID: UUID,
        expiration: Date,
        issuedAt: Date? = nil,
        jti: String = UUID().uuidString,
        hpid: String? = nil,
    ) {
        subject = .init(value: userID.uuidString)
        self.expiration = .init(value: expiration)
        self.issuedAt = issuedAt.map { IssuedAtClaim(value: $0) }
        self.jti = jti
        self.hpid = hpid
    }

    func verify(using _: some JWTAlgorithm) async throws {
        try expiration.verifyNotExpired()
    }

    var userID: UUID? {
        UUID(uuidString: subject.value)
    }
}
