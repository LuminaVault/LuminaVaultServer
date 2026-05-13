@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
import LuminaVaultShared

/// End-to-end tests for `GET /v1/onboarding` and `PATCH /v1/onboarding`
/// (HER-93). Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct OnboardingTests {
    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("onb-\(suffix)@test.luminavault", "onb-\(suffix)")
    }

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func decodeAuthResponse(_ buffer: ByteBuffer) throws -> AuthResponse {
        let data = Data(buffer: buffer)
        return try testJSONDecoder().decode(AuthResponse.self, from: data)
    }

    private static func decodeOnboarding(_ buffer: ByteBuffer) throws -> OnboardingStateDTO {
        // Hummingbird's default JSONEncoder uses `deferredToDate` (Double seconds
        // since 2001-01-01); keep the matching default on the decoder.
        try testJSONDecoder().decode(OnboardingStateDTO.self, from: Data(buffer: buffer))
    }

    private static func register(client: some TestClientProtocol) async throws -> (token: String, email: String, username: String) {
        let (email, username) = randomUser()
        let resp = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: email, username: username, password: "CorrectHorseBatteryStaple1!"),
        ) { try decodeAuthResponse($0.body) }
        return (resp.accessToken, email, username)
    }

    @Test
    func `get returns fresh state for new user`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, _, _) = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/onboarding",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let state = try Self.decodeOnboarding(response.body)
                // First GET auto-creates the row with `signup` already latched.
                #expect(state.signupCompleted == true)
                #expect(state.signupCompletedAt != nil)
                #expect(state.emailVerifiedCompleted == false)
                #expect(state.soulConfiguredCompleted == false)
                #expect(state.firstCaptureCompleted == false)
                #expect(state.firstKBCompileCompleted == false)
                #expect(state.firstQueryCompleted == false)
            }
        }
    }

    @Test
    func `patch sets flag and timestamp`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, _, _) = try await Self.register(client: client)
            let body = ByteBuffer(string: #"{"emailVerifiedCompleted":true,"soulConfiguredCompleted":true}"#)
            try await client.execute(
                uri: "/v1/onboarding",
                method: .patch,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body,
            ) { response in
                #expect(response.status == .ok)
                let state = try Self.decodeOnboarding(response.body)
                #expect(state.emailVerifiedCompleted == true)
                #expect(state.emailVerifiedCompletedAt != nil)
                #expect(state.soulConfiguredCompleted == true)
                #expect(state.soulConfiguredCompletedAt != nil)
                #expect(state.firstCaptureCompleted == false)
            }
        }
    }

    @Test
    func `patch is idempotent does not overwrite timestamp`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, _, _) = try await Self.register(client: client)
            let body = ByteBuffer(string: #"{"firstCaptureCompleted":true}"#)

            let first = try await client.execute(
                uri: "/v1/onboarding",
                method: .patch,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body,
            ) { try Self.decodeOnboarding($0.body) }
            #expect(first.firstCaptureCompleted == true)
            let firstAt = first.firstCaptureCompletedAt
            #expect(firstAt != nil)

            // Sleep > 1s so a re-write would produce a visibly different ts.
            try await Task.sleep(nanoseconds: 1_100_000_000)

            let second = try await client.execute(
                uri: "/v1/onboarding",
                method: .patch,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body,
            ) { try Self.decodeOnboarding($0.body) }
            #expect(second.firstCaptureCompleted == true)
            #expect(second.firstCaptureCompletedAt == firstAt)
        }
    }

    @Test
    func `patch rejects false values`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, _, _) = try await Self.register(client: client)
            let body = ByteBuffer(string: #"{"firstQueryCompleted":false}"#)
            try await client.execute(
                uri: "/v1/onboarding",
                method: .patch,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body,
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test
    func `unauthenticated returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/onboarding", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
            try await client.execute(
                uri: "/v1/onboarding",
                method: .patch,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"firstQueryCompleted":true}"#),
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `get is stable across calls`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, _, _) = try await Self.register(client: client)
            let one = try await client.execute(
                uri: "/v1/onboarding",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { try Self.decodeOnboarding($0.body) }
            let two = try await client.execute(
                uri: "/v1/onboarding",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { try Self.decodeOnboarding($0.body) }
            #expect(one.signupCompletedAt == two.signupCompletedAt)
        }
    }
}
