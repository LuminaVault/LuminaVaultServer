@testable import App
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import JWTKit
import Testing

/// HER-239 — pins the gates in `GoogleOAuthProvider.verify(idToken:)`:
/// audience, issuer (both legacy + canonical), email presence,
/// `email_verified`, and expiry. These are pure verifier tests; the DB
/// upsert path (`AuthService.upsertOAuthUser`) is covered by AuthFlowTests.
///
/// The test RSA-2048 keypair is the same well-known fixture JWTKit uses
/// in its own RSATests — non-secret, intentionally reused so the keysize
/// guard passes without ad-hoc key generation.
@Suite(.serialized, .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct GoogleOAuthProviderTests {
    // MARK: - Constants

    private static let testAudience = "test-client.apps.googleusercontent.com"
    private static let testKID = "google-test-key"
    private static let jwksURL = URL(string: "https://stub.test/oauth2/v3/certs")!

    /// JWTKit RSATests' published test modulus (n) — base64url, 2048-bit.
    private static let testModulus = """
    vTHHoCaR0tlYfvapRv94hUTMrdSymIrWIIZ5Kmv5bIYWtK0TMX0icLkB0PzR2IDLj1L7hzBKUljBGzjf6ujfZwru5-odDZ344A6AhH5B5Zie1ALUTnizD-8XtWcdOtv4aF5NwgRJns0YY-HVr_KKfPZurfMf7JI2wSCt0TRRUixkfJgypnLNZNMowcMiGD9GYdCb2mC43V8DKNpUIIIUJK_auxqAxdEnY6GwI4zYnQdCv8ULai_LcB2CQhj5gm9PeKI6K1qkKs5_F1N2-2y9srrSk7pYPU0xxrj5Ap5GsTaJJJhV9QV1bgDiJaakWhh2m9jSs6SsufHCPT5RiCVh5Q
    """

    private static let testPublicExponent = "AQAB"

    private static let testPrivateExponent = """
    B0fVIMqbLfwDNc-UMBFAuBAvuDjJLqmZF-NU4lcJYC3Aze8jH_Jq0t-rvDkecjBypO9Skp8_HPAhbkTACTAw-KwpCW-u8okzvJuSQocBTi6TXiFFvkdSzLgst2RicZNpecq3P1Ie6yeFWsKkEINK5Qguti72-Yme5cu2JKjYwEq37c94_hNdD4CPY7XebgcXeb8dnqr40--WVIbyxSYl5uV6ZRx7vQGXyZwFezhgoyYMhkoRs88iukTeOjs_MRfmTr-akfYm67Pzwm0bC7gHU0aNS_apl7KDNfIO2MOE11WDYKmul1VmH6N0mEaxdOa_Mw5S0JlB9szX3lAEd5-buQ
    """

    // MARK: - Fixture

    fileprivate struct Fixture {
        let signer: JWTKeyCollection
        let provider: GoogleOAuthProvider
    }

    private static func makeFixture(
        audience: String = Self.testAudience
    ) async throws -> Fixture {
        let normalizedModulus = Self.testModulus
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")
        let normalizedPrivateExponent = Self.testPrivateExponent
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")

        let privateKey = try Insecure.RSA.PrivateKey(
            modulus: normalizedModulus,
            exponent: Self.testPublicExponent,
            privateExponent: normalizedPrivateExponent
        )
        let signer = JWTKeyCollection()
        await signer.add(
            rsa: privateKey,
            digestAlgorithm: .sha256,
            kid: JWKIdentifier(string: Self.testKID)
        )

        let jwks = #"""
        {"keys":[{"kty":"RSA","kid":"\#(Self.testKID)","alg":"RS256","use":"sig","n":"\#(normalizedModulus)","e":"\#(Self.testPublicExponent)"}]}
        """#

        StubJWKSURLProtocol.configure(url: Self.jwksURL, body: jwks)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubJWKSURLProtocol.self]
        let session = URLSession(configuration: config)

        let provider = GoogleOAuthProvider(
            audience: audience,
            jwksURL: Self.jwksURL,
            session: session
        )
        return Fixture(signer: signer, provider: provider)
    }

    // MARK: - Test token builder

    private struct TestIDClaims: JWTPayload {
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

    private static func signToken(
        on signer: JWTKeyCollection,
        sub: String = "google-sub-12345",
        aud: String = Self.testAudience,
        iss: String = "https://accounts.google.com",
        email: String? = "ok@example.com",
        emailVerified: Bool? = true,
        exp: Date = Date().addingTimeInterval(60 * 5)
    ) async throws -> String {
        let claims = TestIDClaims(
            sub: SubjectClaim(value: sub),
            aud: AudienceClaim(value: [aud]),
            iss: IssuerClaim(value: iss),
            exp: ExpirationClaim(value: exp),
            email: email,
            emailVerified: emailVerified
        )
        return try await signer.sign(claims, kid: JWKIdentifier(string: Self.testKID))
    }

    // MARK: - Tests

    @Test
    func `valid token returns identity`() async throws {
        let fix = try await Self.makeFixture()
        let token = try await Self.signToken(on: fix.signer)
        let info = try await fix.provider.verify(idToken: token)
        #expect(info.providerUserID == "google-sub-12345")
        #expect(info.email == "ok@example.com")
        #expect(info.emailVerified == true)
    }

    @Test
    func `wrong audience throws invalid token`() async throws {
        let fix = try await Self.makeFixture()
        let token = try await Self.signToken(
            on: fix.signer,
            aud: "other-client.apps.googleusercontent.com"
        )
        await #expect(throws: OAuthError.invalidToken) {
            _ = try await fix.provider.verify(idToken: token)
        }
    }

    @Test
    func `wrong issuer throws invalid token`() async throws {
        let fix = try await Self.makeFixture()
        let token = try await Self.signToken(
            on: fix.signer,
            iss: "https://impostor.example.com"
        )
        await #expect(throws: OAuthError.invalidToken) {
            _ = try await fix.provider.verify(idToken: token)
        }
    }

    @Test
    func `missing email throws missing claims`() async throws {
        let fix = try await Self.makeFixture()
        let token = try await Self.signToken(on: fix.signer, email: nil)
        await #expect(throws: OAuthError.missingClaims) {
            _ = try await fix.provider.verify(idToken: token)
        }
    }

    @Test
    func `empty email throws missing claims`() async throws {
        let fix = try await Self.makeFixture()
        let token = try await Self.signToken(on: fix.signer, email: "")
        await #expect(throws: OAuthError.missingClaims) {
            _ = try await fix.provider.verify(idToken: token)
        }
    }

    @Test
    func `unverified email throws unverified email`() async throws {
        let fix = try await Self.makeFixture()
        let token = try await Self.signToken(on: fix.signer, emailVerified: false)
        await #expect(throws: OAuthError.unverifiedEmail) {
            _ = try await fix.provider.verify(idToken: token)
        }
    }

    @Test
    func `missing email verified claim throws unverified email`() async throws {
        let fix = try await Self.makeFixture()
        let token = try await Self.signToken(on: fix.signer, emailVerified: nil)
        await #expect(throws: OAuthError.unverifiedEmail) {
            _ = try await fix.provider.verify(idToken: token)
        }
    }

    @Test
    func `expired token throws`() async throws {
        let fix = try await Self.makeFixture()
        let token = try await Self.signToken(
            on: fix.signer,
            exp: Date().addingTimeInterval(-60)
        )
        await #expect(throws: (any Error).self) {
            _ = try await fix.provider.verify(idToken: token)
        }
    }

    @Test
    func `valid token accepts canonical issuer`() async throws {
        let fix = try await Self.makeFixture()
        let token = try await Self.signToken(on: fix.signer, iss: "accounts.google.com")
        let info = try await fix.provider.verify(idToken: token)
        #expect(info.providerUserID == "google-sub-12345")
    }
}

// MARK: - Stub URLProtocol

/// Intercepts JWKS fetches inside `JWKSCache.current()` so tests can serve
/// a fixed JWKS body without hitting `googleapis.com`. Configured globally
/// per Suite invocation via `configure(url:body:)`.
final class StubJWKSURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var expectedURL: URL?
    private nonisolated(unsafe) static var responseBody: String?

    static func configure(url: URL, body: String) {
        lock.lock()
        defer { lock.unlock() }
        expectedURL = url
        responseBody = body
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let expected = expectedURL else { return false }
        return request.url == expected
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let body = Self.responseBody ?? "{}"
        let url = Self.expectedURL ?? request.url!
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
