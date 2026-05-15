@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

/// HER-217 — `/v1/settings/hermes` E2E. Runs against the real router
/// + Postgres. Requires `docker compose up -d postgres`. Reuses
/// `dbTestReader` which pins `secret.masterKey` + `byoHermes.allowPrivate`
/// so the BYO Hermes route group mounts and accepts loopback URLs.
///
/// Does NOT cover `POST /v1/settings/hermes/test` — that endpoint
/// dials the configured upstream and would need a `URLSession`
/// fixture. Probe behaviour is exercised in a follow-up commit.
@Suite(.serialized)
struct HermesConfigControllerTests {
    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("byo-\(suffix)@test.luminavault", "byo-\(suffix)")
    }

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func decodeAuth(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeGet(_ buffer: ByteBuffer) throws -> HermesConfigController.GetResponse {
        try testJSONDecoder().decode(
            HermesConfigController.GetResponse.self,
            from: Data(buffer: buffer),
        )
    }

    private static func register(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        let body = registerBody(email: email, username: username, password: "CorrectHorseBatteryStaple1!")
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body,
        ) { try decodeAuth($0.body).accessToken }
    }

    @Test
    func `GET 404 when no row exists`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/settings/hermes",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func `PUT then GET round-trips and reports hasAuthHeader`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)

            let putBody = ByteBuffer(string: #"{"baseUrl":"http://127.0.0.1:9999","authHeader":"Bearer abc"}"#)
            try await client.execute(
                uri: "/v1/settings/hermes",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: putBody,
            ) { response in
                #expect(response.status == .ok)
                let resp = try Self.decodeGet(response.body)
                #expect(resp.baseUrl == "http://127.0.0.1:9999")
                #expect(resp.hasAuthHeader == true)
                #expect(resp.verifiedAt == nil)
            }

            try await client.execute(
                uri: "/v1/settings/hermes",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let resp = try Self.decodeGet(response.body)
                #expect(resp.baseUrl == "http://127.0.0.1:9999")
                #expect(resp.hasAuthHeader == true)
                #expect(resp.verifiedAt == nil)
            }
        }
    }

    @Test
    func `GET response never echoes plaintext auth header`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let putBody = ByteBuffer(string: #"{"baseUrl":"http://127.0.0.1:9999","authHeader":"Bearer SECRET-TOKEN-XYZ"}"#)
            _ = try await client.execute(
                uri: "/v1/settings/hermes",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: putBody,
            ) { $0.status }

            try await client.execute(
                uri: "/v1/settings/hermes",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                let body = String(buffer: response.body)
                #expect(!body.contains("SECRET-TOKEN-XYZ"))
                #expect(!body.contains("authHeader"))
            }
        }
    }

    @Test
    func `PUT without authHeader reports hasAuthHeader false`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let putBody = ByteBuffer(string: #"{"baseUrl":"http://127.0.0.1:9999"}"#)
            try await client.execute(
                uri: "/v1/settings/hermes",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: putBody,
            ) { response in
                #expect(response.status == .ok)
                let resp = try Self.decodeGet(response.body)
                #expect(resp.hasAuthHeader == false)
            }
        }
    }

    @Test
    func `PUT rejects loopback when allowPrivate disabled by SSRFGuard`() async throws {
        // dbTestReader pins allowPrivate=true so the happy-path tests
        // above can use 127.0.0.1. Confirm the negative path is wired
        // by building a guard directly — full request-level rejection
        // requires a separate reader and is covered by SSRFGuardTests.
        let guardian = SSRFGuard(
            allowPrivateRanges: false,
            environment: "prod",
            resolver: SSRFGuardTests.StubResolver(answers: ["127.0.0.1": ["127.0.0.1"]]),
        )
        await #expect(throws: SSRFGuard.Rejection.self) {
            _ = try await guardian.validate(rawURL: "https://127.0.0.1")
        }
    }

    @Test
    func `DELETE drops the row and GET returns 404`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)

            let putBody = ByteBuffer(string: #"{"baseUrl":"http://127.0.0.1:9999"}"#)
            _ = try await client.execute(
                uri: "/v1/settings/hermes",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: putBody,
            ) { $0.status }

            try await client.execute(
                uri: "/v1/settings/hermes",
                method: .delete,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .noContent)
            }

            try await client.execute(
                uri: "/v1/settings/hermes",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func `PUT resets verifiedAt`() async throws {
        // PUT is the only contract for updating; it always resets
        // verified_at = nil so iOS surfaces the unverified state.
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let body1 = ByteBuffer(string: #"{"baseUrl":"http://127.0.0.1:9999"}"#)
            let body2 = ByteBuffer(string: #"{"baseUrl":"http://127.0.0.1:8888","authHeader":"Bearer new"}"#)

            _ = try await client.execute(
                uri: "/v1/settings/hermes",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body1,
            ) { $0.status }
            try await client.execute(
                uri: "/v1/settings/hermes",
                method: .put,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: body2,
            ) { response in
                #expect(response.status == .ok)
                let resp = try Self.decodeGet(response.body)
                #expect(resp.baseUrl == "http://127.0.0.1:8888")
                #expect(resp.hasAuthHeader == true)
                #expect(resp.verifiedAt == nil)
            }
        }
    }

    @Test
    func `unauthenticated request returns 401`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/settings/hermes", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }
}
