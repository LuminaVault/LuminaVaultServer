import Foundation
import JWTKit
import Testing

@testable import App

@Suite struct SessionTokenTests {
    @Test func roundTripsThroughHMAC() async throws {
        let keys = JWTKeyCollection()
        let kid = JWKIdentifier(string: "test")
        await keys.add(hmac: HMACKey(stringLiteral: "secret-secret-secret-32chars-x"),
                       digestAlgorithm: .sha256, kid: kid)
        let userID = UUID()
        let token = SessionToken(userID: userID, expiration: Date().addingTimeInterval(3600))
        let signed = try await keys.sign(token, kid: kid)
        let decoded = try await keys.verify(signed, as: SessionToken.self)
        #expect(decoded.userID == userID)
    }

    @Test func rejectsExpiredToken() async throws {
        let keys = JWTKeyCollection()
        let kid = JWKIdentifier(string: "test")
        await keys.add(hmac: HMACKey(stringLiteral: "secret-secret-secret-32chars-x"),
                       digestAlgorithm: .sha256, kid: kid)
        let token = SessionToken(userID: UUID(), expiration: Date().addingTimeInterval(-1))
        let signed = try await keys.sign(token, kid: kid)
        await #expect(throws: (any Error).self) {
            _ = try await keys.verify(signed, as: SessionToken.self)
        }
    }
}
