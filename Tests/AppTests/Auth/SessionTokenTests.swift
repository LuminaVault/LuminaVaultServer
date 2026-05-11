@testable import App
import Foundation
import JWTKit
import Testing

struct SessionTokenTests {
    private static func makeKeys() async -> (JWTKeyCollection, JWKIdentifier) {
        let keys = JWTKeyCollection()
        let kid = JWKIdentifier(string: "test")
        await keys.add(hmac: HMACKey(stringLiteral: "secret-secret-secret-32chars-x"),
                       digestAlgorithm: .sha256, kid: kid)
        return (keys, kid)
    }

    @Test func `round trips through HMAC`() async throws {
        let (keys, kid) = await Self.makeKeys()
        let userID = UUID()
        let token = SessionToken(userID: userID, expiration: Date().addingTimeInterval(3600))
        let signed = try await keys.sign(token, kid: kid)
        let decoded = try await keys.verify(signed, as: SessionToken.self)
        #expect(decoded.userID == userID)
        // Tokens minted without hpid (legacy path) decode as nil via the
        // Optional Codable representation — proves forward-compat.
        #expect(decoded.hpid == nil)
    }

    @Test func `rejects expired token`() async throws {
        let (keys, kid) = await Self.makeKeys()
        let token = SessionToken(userID: UUID(), expiration: Date().addingTimeInterval(-1))
        let signed = try await keys.sign(token, kid: kid)
        await #expect(throws: (any Error).self) {
            _ = try await keys.verify(signed, as: SessionToken.self)
        }
    }

    @Test func `hpid claim round trips`() async throws {
        let (keys, kid) = await Self.makeKeys()
        let userID = UUID()
        let token = SessionToken(
            userID: userID,
            expiration: Date().addingTimeInterval(3600),
            hpid: "hermes-alice",
        )
        let signed = try await keys.sign(token, kid: kid)
        let decoded = try await keys.verify(signed, as: SessionToken.self)
        #expect(decoded.userID == userID)
        #expect(decoded.hpid == "hermes-alice")
    }
}
