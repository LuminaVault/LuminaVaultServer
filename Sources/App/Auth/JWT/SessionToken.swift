import Foundation
import JWTKit

/// Access token payload. HMAC HS256 signed.
/// `sub` carries the user UUID (= tenantID).
struct SessionToken: JWTPayload, Sendable {
    var subject: SubjectClaim
    var expiration: ExpirationClaim
    var jti: String

    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
        case jti
    }

    init(userID: UUID, expiration: Date, jti: String = UUID().uuidString) {
        self.subject = .init(value: userID.uuidString)
        self.expiration = .init(value: expiration)
        self.jti = jti
    }

    func verify(using _: some JWTAlgorithm) async throws {
        try expiration.verifyNotExpired()
    }

    var userID: UUID? { UUID(uuidString: subject.value) }
}
