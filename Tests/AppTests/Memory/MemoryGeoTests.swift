@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// HER-207 — end-to-end tests for the optional `(lat, lng, accuracy_m,
/// place_name)` geo columns on the `memories` table. Boots the full
/// Hummingbird app + Postgres so the Memory model, the M36 migration,
/// MemoryController::upsert, and MemoryDTO.fromMemory are all exercised
/// against a real schema. Run with `docker compose up -d postgres`.
@Suite(.serialized)
struct MemoryGeoTests {
    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func decodeAuthResponse(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeUpsert(_ buffer: ByteBuffer) throws -> MemoryUpsertResponse {
        try testJSONDecoder().decode(MemoryUpsertResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeOne(_ buffer: ByteBuffer) throws -> MemoryDTO {
        try testJSONDecoder().decode(MemoryDTO.self, from: Data(buffer: buffer))
    }

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("geo-\(suffix)@test.luminavault", "geo-\(suffix)")
    }

    private static func registerAndAuth(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        let resp = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: email, username: username, password: "CorrectHorseBatteryStaple1!"),
        ) { try decodeAuthResponse($0.body) }
        return resp.accessToken
    }

    /// Posts `MemoryUpsertRequest` from `LuminaVaultShared` so the wire
    /// shape under test is the one iOS will send. Returns the new
    /// memory's id.
    private static func upsert(
        client: some TestClientProtocol,
        token: String,
        request: MemoryUpsertRequest,
    ) async throws -> UUID {
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        return try await client.execute(
            uri: "/v1/memory/upsert",
            method: .post,
            headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
            body: ByteBuffer(data: data),
        ) { try decodeUpsert($0.body).memoryId }
    }

    private static func fetch(
        client: some TestClientProtocol,
        token: String,
        id: UUID,
    ) async throws -> MemoryDTO {
        try await client.execute(
            uri: "/v1/memory/\(id.uuidString)",
            method: .get,
            headers: [.authorization: "Bearer \(token)"],
        ) { try decodeOne($0.body) }
    }

    @Test
    func `upsert with full geo persists all four columns`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let request = MemoryUpsertRequest(
                content: "had coffee at A Brasileira",
                lat: 38.7106,
                lng: -9.1418,
                accuracyM: 12.5,
                placeName: "Café A Brasileira, Lisbon",
            )
            let id = try await Self.upsert(client: client, token: token, request: request)

            let dto = try await Self.fetch(client: client, token: token, id: id)
            #expect(dto.lat == 38.7106)
            #expect(dto.lng == -9.1418)
            #expect(dto.accuracyM == 12.5)
            #expect(dto.placeName == "Café A Brasileira, Lisbon")
        }
    }

    @Test
    func `upsert without geo leaves columns null`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let request = MemoryUpsertRequest(content: "plain memory, no location")
            let id = try await Self.upsert(client: client, token: token, request: request)

            let dto = try await Self.fetch(client: client, token: token, id: id)
            #expect(dto.lat == nil)
            #expect(dto.lng == nil)
            #expect(dto.accuracyM == nil)
            #expect(dto.placeName == nil)
        }
    }

    @Test
    func `partial geo persists supplied fields only`() async throws {
        // Lat/lng without place_name is a legitimate state (e.g. offline
        // capture queued before reverse-geocoding completed). Verify the
        // server doesn't reject the request and that the missing field
        // round-trips as nil.
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.registerAndAuth(client: client)
            let request = MemoryUpsertRequest(
                content: "queued before geocode finished",
                lat: 38.7,
                lng: -9.14,
                accuracyM: 25.0,
                placeName: nil,
            )
            let id = try await Self.upsert(client: client, token: token, request: request)

            let dto = try await Self.fetch(client: client, token: token, id: id)
            #expect(dto.lat == 38.7)
            #expect(dto.lng == -9.14)
            #expect(dto.accuracyM == 25.0)
            #expect(dto.placeName == nil)
        }
    }
}
