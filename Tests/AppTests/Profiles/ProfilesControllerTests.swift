@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import struct LuminaVaultShared.AuthResponse
import struct LuminaVaultShared.HermesProfileActivateResponse
import struct LuminaVaultShared.HermesProfileCreateRequest
import struct LuminaVaultShared.HermesProfileDTO
import struct LuminaVaultShared.HermesProfilePatchRequest
import struct LuminaVaultShared.HermesProfilesListResponse
import Testing

/// HER-273 — `/v1/profiles` E2E. Runs against the real router +
/// Postgres (`docker compose up -d postgres`). Mirrors the
/// `HermesGatewaysControllerTests` shape: register a fresh user per
/// test, drive the routes, assert the wire response.
@Suite(.serialized)
struct ProfilesControllerTests {
    // MARK: - Fixtures

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("prof-\(suffix)@test.luminavault", "prof-\(suffix)")
    }

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func decodeAuth(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeList(_ buffer: ByteBuffer) throws -> HermesProfilesListResponse {
        try testJSONDecoder().decode(HermesProfilesListResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeDTO(_ buffer: ByteBuffer) throws -> HermesProfileDTO {
        try testJSONDecoder().decode(HermesProfileDTO.self, from: Data(buffer: buffer))
    }

    private static func decodeActivate(_ buffer: ByteBuffer) throws -> HermesProfileActivateResponse {
        try testJSONDecoder().decode(HermesProfileActivateResponse.self, from: Data(buffer: buffer))
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

    private static func createBody(_ payload: HermesProfileCreateRequest) throws -> ByteBuffer {
        let data = try testJSONEncoder().encode(payload)
        return ByteBuffer(data: data)
    }

    private static func patchBody(_ payload: HermesProfilePatchRequest) throws -> ByteBuffer {
        let data = try testJSONEncoder().encode(payload)
        return ByteBuffer(data: data)
    }

    // MARK: - Tests

    @Test
    func `GET list on a fresh tenant returns empty items + nil activeSlug`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/profiles",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let list = try Self.decodeList(response.body)
                #expect(list.items.isEmpty)
                #expect(list.activeSlug == nil)
            }
        }
    }

    @Test
    func `POST first profile becomes default, second does not`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)

            let first = try await client.execute(
                uri: "/v1/profiles",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: Self.createBody(.init(slug: "stocks", label: "Stocks", templateSlug: "stocks-tracker")),
            ) { response -> HermesProfileDTO in
                #expect(response.status == .ok)
                return try Self.decodeDTO(response.body)
            }
            #expect(first.isDefault)
            #expect(first.slug == "stocks")
            #expect(first.systemPrompt.contains("equities"))

            let second = try await client.execute(
                uri: "/v1/profiles",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: Self.createBody(.init(slug: "news", label: "News")),
            ) { response -> HermesProfileDTO in
                #expect(response.status == .ok)
                return try Self.decodeDTO(response.body)
            }
            #expect(!second.isDefault)
        }
    }

    @Test
    func `POST duplicate slug returns 409 slug_already_exists`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/profiles",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: Self.createBody(.init(slug: "stocks", label: "Stocks")),
            ) { #expect($0.status == .ok) }
            try await client.execute(
                uri: "/v1/profiles",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: Self.createBody(.init(slug: "stocks", label: "Stocks 2")),
            ) { response in
                #expect(response.status == .conflict)
            }
        }
    }

    @Test
    func `POST invalid slug returns 400 invalid_slug`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/profiles",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: Self.createBody(.init(slug: "Has Spaces!", label: "x")),
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test
    func `PATCH updates label and system prompt`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/profiles",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: Self.createBody(.init(slug: "stocks", label: "Stocks")),
            ) { #expect($0.status == .ok) }
            try await client.execute(
                uri: "/v1/profiles/stocks",
                method: .patch,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: Self.patchBody(.init(label: "Stocks Pro", systemPrompt: "Focus on options flow.")),
            ) { response in
                #expect(response.status == .ok)
                let dto = try Self.decodeDTO(response.body)
                #expect(dto.label == "Stocks Pro")
                #expect(dto.systemPrompt == "Focus on options flow.")
            }
        }
    }

    @Test
    func `POST activate switches the default flag atomically`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/profiles",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: Self.createBody(.init(slug: "stocks", label: "Stocks")),
            ) { #expect($0.status == .ok) }
            try await client.execute(
                uri: "/v1/profiles",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: Self.createBody(.init(slug: "news", label: "News")),
            ) { #expect($0.status == .ok) }
            try await client.execute(
                uri: "/v1/profiles/news/activate",
                method: .post,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let ack = try Self.decodeActivate(response.body)
                #expect(ack.slug == "news")
            }
            try await client.execute(
                uri: "/v1/profiles",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let list = try Self.decodeList(response.body)
                #expect(list.activeSlug == "news")
                let news = list.items.first { $0.slug == "news" }
                #expect(news?.isDefault == true)
                let stocks = list.items.first { $0.slug == "stocks" }
                #expect(stocks?.isDefault == false)
            }
        }
    }

    @Test
    func `DELETE default returns 409 cannot_delete_default`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/profiles",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: Self.createBody(.init(slug: "stocks", label: "Stocks")),
            ) { #expect($0.status == .ok) }
            try await client.execute(
                uri: "/v1/profiles/stocks",
                method: .delete,
                headers: [.authorization: "Bearer \(token)"],
            ) { #expect($0.status == .conflict) }
        }
    }

    @Test
    func `DELETE non-default returns 204`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/profiles",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: Self.createBody(.init(slug: "stocks", label: "Stocks")),
            ) { #expect($0.status == .ok) }
            try await client.execute(
                uri: "/v1/profiles",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: Self.createBody(.init(slug: "news", label: "News")),
            ) { #expect($0.status == .ok) }
            try await client.execute(
                uri: "/v1/profiles/news",
                method: .delete,
                headers: [.authorization: "Bearer \(token)"],
            ) { #expect($0.status == .noContent) }
        }
    }

    @Test
    func `GET unknown slug returns 404 profile_not_found`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/profiles/ghost",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { #expect($0.status == .notFound) }
        }
    }
}
