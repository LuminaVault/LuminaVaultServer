@testable import App
import Foundation
import JWTKit
import Testing

/// HER-33 JWT key rotation. `parseJWTSecrets` turns the `JWT_HMAC_SECRETS`
/// csv (`kid1:secret1,kid2:secret2`) into ordered key material; the first
/// entry is the active signer, the rest verify in-flight tokens during a
/// rollover window.
struct JWTKeyLoaderTests {
    private static let secretA = String(repeating: "a", count: 32)
    private static let secretB = String(repeating: "b", count: 32)

    // MARK: - parser

    @Test
    func `parses csv into ordered kid/secret pairs`() throws {
        let parsed = try parseJWTSecrets("kid1:\(Self.secretA),kid2:\(Self.secretB)")
        #expect(parsed.count == 2)
        #expect(parsed[0].kid.string == "kid1")
        #expect(parsed[0].secret == Self.secretA)
        #expect(parsed[1].kid.string == "kid2")
        #expect(parsed[1].secret == Self.secretB)
    }

    @Test
    func `tolerates whitespace around entries`() throws {
        let parsed = try parseJWTSecrets(" kid1 : \(Self.secretA) , kid2 : \(Self.secretB) ")
        #expect(parsed[0].kid.string == "kid1")
        #expect(parsed[1].kid.string == "kid2")
    }

    @Test
    func `empty input yields empty list`() throws {
        #expect(try parseJWTSecrets("").isEmpty)
        #expect(try parseJWTSecrets("   ").isEmpty)
    }

    @Test
    func `rejects entry without colon`() {
        #expect(throws: JWTKeyLoaderError.self) {
            try parseJWTSecrets("noColonHere\(Self.secretA)")
        }
    }

    @Test
    func `rejects empty kid`() {
        #expect(throws: JWTKeyLoaderError.self) {
            try parseJWTSecrets(":\(Self.secretA)")
        }
    }

    @Test
    func `rejects short secret`() {
        #expect(throws: JWTKeyLoaderError.self) {
            try parseJWTSecrets("kid1:tooShort")
        }
    }

    @Test
    func `rejects duplicate kids`() {
        #expect(throws: JWTKeyLoaderError.self) {
            try parseJWTSecrets("kid1:\(Self.secretA),kid1:\(Self.secretB)")
        }
    }

    // MARK: - loader + verify

    @Test
    func `loaded collection verifies token signed by active kid`() async throws {
        let collection = JWTKeyCollection()
        let secrets = try parseJWTSecrets("activeKid:\(Self.secretA),oldKid:\(Self.secretB)")
        try await loadJWTKeys(into: collection, secrets: secrets)

        let payload = TestPayload(sub: "u-1")
        let token = try await collection.sign(payload, kid: JWKIdentifier(string: "activeKid"))
        let verified = try await collection.verify(token, as: TestPayload.self)
        #expect(verified.sub.value == "u-1")
    }

    @Test
    func `tokens signed by retired kid still verify after rotation`() async throws {
        // Initial state: kid1 active, kid2 standby.
        let initialCollection = JWTKeyCollection()
        let initialSecrets = try parseJWTSecrets("kid1:\(Self.secretA),kid2:\(Self.secretB)")
        try await loadJWTKeys(into: initialCollection, secrets: initialSecrets)

        let oldToken = try await initialCollection.sign(
            TestPayload(sub: "u-1"),
            kid: JWKIdentifier(string: "kid1"),
        )

        // Rotate: kid2 promoted to active, kid1 kept for verify-only during
        // the rollover window. Old token must still verify.
        let rotated = JWTKeyCollection()
        let rotatedSecrets = try parseJWTSecrets("kid2:\(Self.secretB),kid1:\(Self.secretA)")
        try await loadJWTKeys(into: rotated, secrets: rotatedSecrets)

        let verified = try await rotated.verify(oldToken, as: TestPayload.self)
        #expect(verified.sub.value == "u-1")
    }

    @Test
    func `tokens signed by fully removed kid fail verification`() async throws {
        // Rollover window expired — kid1 dropped, only kid2 remains.
        let original = JWTKeyCollection()
        try await loadJWTKeys(
            into: original,
            secrets: parseJWTSecrets("kid1:\(Self.secretA)"),
        )
        let token = try await original.sign(
            TestPayload(sub: "u-1"),
            kid: JWKIdentifier(string: "kid1"),
        )

        let postRotation = JWTKeyCollection()
        try await loadJWTKeys(
            into: postRotation,
            secrets: parseJWTSecrets("kid2:\(Self.secretB)"),
        )
        await #expect(throws: (any Error).self) {
            _ = try await postRotation.verify(token, as: TestPayload.self)
        }
    }
}

private struct TestPayload: JWTPayload {
    var sub: SubjectClaim
    init(sub: String) {
        self.sub = SubjectClaim(value: sub)
    }

    func verify(using _: some JWTAlgorithm) async throws {}
}
