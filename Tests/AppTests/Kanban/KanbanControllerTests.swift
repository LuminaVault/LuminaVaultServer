@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import LuminaVaultShared
import Testing

/// Compile-only router bootstrap for the native Kanban surface.
/// These tests require a live Postgres instance (dbTestReader) and are
/// not run in CI (HER-310 — `test` job is non-required). They only need
/// to compile under `swift build --build-tests`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct KanbanControllerTests {
    // MARK: - Helpers

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("kanban-\(suffix)@test.luminavault", "kanban-\(suffix)")
    }

    private static func registerBody(email: String, username: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"CorrectHorseBatteryStaple1!"}
        """)
    }

    private static func decodeAuth(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
    }

    private static func decodeBoard(_ buffer: ByteBuffer) throws -> BoardDTO {
        try testJSONDecoder().decode(BoardDTO.self, from: Data(buffer: buffer))
    }

    private static func decodeBoardList(_ buffer: ByteBuffer) throws -> [BoardSummaryDTO] {
        try testJSONDecoder().decode([BoardSummaryDTO].self, from: Data(buffer: buffer))
    }

    private static func register(client: some TestClientProtocol) async throws -> String {
        let (email, username) = randomUser()
        let resp = try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: registerBody(email: email, username: username)
        ) { try decodeAuth($0.body) }
        return resp.accessToken
    }

    // MARK: - Tests

    /// GET /v1/boards auto-creates the default board (3 columns) on first call
    /// and returns 200 with at least one board summary.
    @Test
    func `GET boards returns 200 with auto-created board`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)

            // First call auto-creates the default board.
            try await client.execute(
                uri: "/v1/boards",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let boards = try Self.decodeBoardList(response.body)
                #expect(!boards.isEmpty)
                // The default board is seeded with 3 columns (Todo / Doing / Done).
                #expect(boards[0].columnCount == 3)
            }
        }
    }
}
