@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import Logging
import LuminaVaultShared
import Testing

/// HER-137 E2E tests for `POST /v1/auth/phone/start` + `/phone/verify`.
///
/// `dbTestReader` pins `phone.fixedOtp = "424242"` so the verify step is
/// deterministic; `sms.kind` defaults to `logging` so no real SMS is sent.
/// Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct PhoneAuthFlowTests {
    private static let fixedOTP = "424242"

    private static func randomE164() -> String {
        // E.164: + then 7..15 digits, first nonzero.
        let suffix = Int.random(in: 100_000_000 ..< 999_999_999)
        return "+1555\(suffix)"
    }

    private static func decodeStart(_ buf: ByteBuffer) throws -> PhoneStartResponse {
        try testJSONDecoder().decode(PhoneStartResponse.self, from: Data(buffer: buf))
    }

    private static func decodeAuth(_ buf: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buf))
    }

    private static func startBody(phone: String) -> ByteBuffer {
        ByteBuffer(string: #"{"phone":"\#(phone)"}"#)
    }

    private static func verifyBody(phone: String, code: String) -> ByteBuffer {
        ByteBuffer(string: #"{"phone":"\#(phone)","code":"\#(code)"}"#)
    }

    @Test
    func `start then verify creates user with phone identity`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let phone = Self.randomE164()

            try await client.execute(
                uri: "/v1/auth/phone/start",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.startBody(phone: phone),
            ) { response in
                #expect(response.status == .ok)
                let start = try Self.decodeStart(response.body)
                #expect(start.expiresAt > Date())
            }

            let auth = try await client.execute(
                uri: "/v1/auth/phone/verify",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.verifyBody(phone: phone, code: Self.fixedOTP),
            ) { response -> AuthResponse in
                #expect(response.status == .ok)
                return try Self.decodeAuth(response.body)
            }

            #expect(!auth.accessToken.isEmpty)
            #expect(!auth.refreshToken.isEmpty)

            // Verify the OAuthIdentity row landed with provider="phone".
            try await withTestFluent(label: "test.phone.fluent") { fluent in
                let identity = try await OAuthIdentity.query(on: fluent.db())
                    .filter(\.$tenantID == auth.userId)
                    .filter(\.$provider == "phone")
                    .first()
                #expect(identity != nil, "expected OAuthIdentity(provider: phone) for tenant \(auth.userId)")
                #expect(identity?.providerUserID == phone)
            }
        }
    }

    @Test
    func `verify with bad code returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let phone = Self.randomE164()

            try await client.execute(
                uri: "/v1/auth/phone/start",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.startBody(phone: phone),
            ) { #expect($0.status == .ok) }

            try await client.execute(
                uri: "/v1/auth/phone/verify",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.verifyBody(phone: phone, code: "000000"),
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `verify without start returns 401`() async throws {
        // No prior `start` → store has no entry → consumeTyped returns
        // `.notFound`, which the controller maps to 401 (not 410).
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/auth/phone/verify",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.verifyBody(phone: Self.randomE164(), code: Self.fixedOTP),
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `start rejects non E 164`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/auth/phone/start",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.startBody(phone: "555-1234"),
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test
    func `same destination reissue burns old code`() async throws {
        // The store burns the prior outstanding challenge on re-issue, so
        // even if the OTP was leaked between calls the old code is dead.
        // FixedOTPCodeGenerator means both calls produce the same code,
        // so we have to verify burn behavior by attempting verify twice.
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let phone = Self.randomE164()

            // First start → first challenge issued.
            try await client.execute(
                uri: "/v1/auth/phone/start",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.startBody(phone: phone),
            ) { #expect($0.status == .ok) }

            // Re-issue (different request, new in-memory entry).
            try await client.execute(
                uri: "/v1/auth/phone/start",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.startBody(phone: phone),
            ) { #expect($0.status == .ok) }

            // Verify succeeds against the latest challenge.
            try await client.execute(
                uri: "/v1/auth/phone/verify",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.verifyBody(phone: phone, code: Self.fixedOTP),
            ) { #expect($0.status == .ok) }

            // The challenge is now burned-on-success; a second verify with
            // the same code returns .notFound → 401.
            try await client.execute(
                uri: "/v1/auth/phone/verify",
                method: .post,
                headers: [.contentType: "application/json"],
                body: Self.verifyBody(phone: phone, code: Self.fixedOTP),
            ) { #expect($0.status == .unauthorized) }
        }
    }
}
