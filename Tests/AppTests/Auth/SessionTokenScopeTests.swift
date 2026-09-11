@testable import App
import Foundation
import JWTKit
import Testing

/// The `scp` claim is the contract between `HermesAudioTokenService` (which
/// mints it), `JWTAuthenticator` (which must refuse it) and
/// `AudioJWTAuthenticator` (which accepts it on one route group). All three
/// key off the same wire name, and nothing else enforces that they agree.
///
/// The security property being protected: a tenant's Hermes container holds a
/// scoped token. If that token ever authenticated a general session, a
/// container compromise would become full account access.
struct SessionTokenScopeTests {
    static func keys() async throws -> (JWTKeyCollection, JWKIdentifier) {
        let kid = JWKIdentifier(string: "test")
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(from: "test-signing-secret-not-a-real-key"), digestAlgorithm: .sha256, kid: kid)
        return (keys, kid)
    }

    @Test
    func scopeSurvivesASignAndVerifyRoundTrip() async throws {
        let (keys, kid) = try await Self.keys()
        let userID = UUID()
        let token = SessionToken(
            userID: userID,
            expiration: Date().addingTimeInterval(3600),
            issuedAt: Date(),
            scp: SessionToken.Scope.audio
        )

        let signed = try await keys.sign(token, kid: kid)
        let decoded = try await keys.verify(signed, as: SessionToken.self)

        #expect(decoded.scp == "audio")
        #expect(decoded.userID == userID)
    }

    /// An ordinary session must stay unscoped, or `JWTAuthenticator` would
    /// start refusing real users.
    @Test
    func ordinarySessionsCarryNoScope() async throws {
        let (keys, kid) = try await Self.keys()
        let token = SessionToken(
            userID: UUID(),
            expiration: Date().addingTimeInterval(3600),
            issuedAt: Date()
        )

        let decoded = try await keys.verify(keys.sign(token, kid: kid), as: SessionToken.self)
        #expect(decoded.scp == nil)
    }

    /// Tokens minted before the claim existed must keep verifying, which is
    /// why `scp` is optional rather than defaulted.
    @Test
    func tokensWithoutTheClaimStillDecode() async throws {
        let (keys, kid) = try await Self.keys()
        // A payload with no `scp` key at all, as older tokens have.
        struct LegacyToken: JWTPayload {
            var sub: SubjectClaim
            var exp: ExpirationClaim
            var jti: String
            func verify(using _: some JWTAlgorithm) async throws {
                try exp.verifyNotExpired()
            }
        }
        let legacy = LegacyToken(
            sub: .init(value: UUID().uuidString),
            exp: .init(value: Date().addingTimeInterval(3600)),
            jti: UUID().uuidString
        )

        let signed = try await keys.sign(legacy, kid: kid)
        let decoded = try await keys.verify(signed, as: SessionToken.self)

        #expect(decoded.scp == nil)
    }

    /// The claim name is wire contract. Renaming it silently would make every
    /// scoped token read as an unscoped session — a privilege escalation, not
    /// a compile error.
    @Test
    func scopeIsEncodedUnderTheExpectedClaimName() async throws {
        let (keys, kid) = try await Self.keys()
        let token = SessionToken(
            userID: UUID(),
            expiration: Date().addingTimeInterval(3600),
            issuedAt: Date(),
            scp: SessionToken.Scope.audio
        )
        let signed = try await keys.sign(token, kid: kid)

        // Decode the payload segment directly rather than trusting our own
        // Codable round-trip.
        let segments = signed.components(separatedBy: ".")
        #expect(segments.count == 3)
        var payloadSegment = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payloadSegment.count % 4 != 0 {
            payloadSegment += "="
        }

        let data = try #require(Data(base64Encoded: payloadSegment))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["scp"] as? String == "audio")
    }

    @Test
    func audioScopeConstantMatchesTheStringOnTheWire() {
        #expect(SessionToken.Scope.audio == "audio")
    }
}
