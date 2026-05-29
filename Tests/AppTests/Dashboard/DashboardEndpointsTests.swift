@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import struct LuminaVaultShared.AuthResponse
import struct LuminaVaultShared.DashboardProfileResponse
import struct LuminaVaultShared.DashboardStatsResponse
import struct LuminaVaultShared.InsightListResponse
import struct LuminaVaultShared.TaskListResponse
import Testing

/// HER-244 — contract tests for the OS Shell Dashboard endpoints:
///   - `GET /v1/dashboard/stats` (fluent-backed counters)
///   - `GET /v1/tasks` (empty-list stub until HER-246)
///   - `GET /v1/insights` (empty-list stub until HER-248)
///
/// Each endpoint must require a Bearer JWT and return its declared
/// `LuminaVaultShared` DTO shape. Real data wiring for Tasks and
/// Insights lands in their respective tickets; here we only enforce
/// the contract.
@Suite(.serialized)
struct DashboardEndpointsTests {
    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("dash-\(suffix)@test.luminavault", "dash-\(suffix)")
    }

    private static func registerBody(email: String, username: String, password: String) -> ByteBuffer {
        ByteBuffer(string: """
        {"email":"\(email)","username":"\(username)","password":"\(password)"}
        """)
    }

    private static func decodeAuth(_ buffer: ByteBuffer) throws -> AuthResponse {
        try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: buffer))
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

    // MARK: - /v1/dashboard/stats

    @Test
    func `dashboard stats requires auth`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/dashboard/stats",
                method: .get,
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `dashboard stats returns zero counters for a fresh tenant`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/dashboard/stats",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let stats = try testJSONDecoder().decode(
                    DashboardStatsResponse.self,
                    from: Data(buffer: response.body),
                )
                #expect(stats.memoriesToday == 0)
                #expect(stats.memoriesTotal == 0)
                #expect(stats.lastCompileAt == nil)
            }
        }
    }

    // MARK: - /v1/dashboard/profile

    @Test
    func `dashboard profile requires auth`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/dashboard/profile",
                method: .get,
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `dashboard profile returns zero counters and level one for a fresh tenant`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/dashboard/profile",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let profile = try testJSONDecoder().decode(
                    DashboardProfileResponse.self,
                    from: Data(buffer: response.body),
                )
                #expect(profile.skillsCount == 0)
                #expect(profile.jobsCount == 0)
                #expect(profile.sessionsCount == 0)
                #expect(profile.badgesEarned == 0)
                #expect(profile.powerXP == 0)
                #expect(profile.powerLevel == 1)
            }
        }
    }

    // MARK: - /v1/tasks

    @Test
    func `tasks list requires auth`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/tasks",
                method: .get,
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `tasks list returns empty list and accepts state and limit query params`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/tasks?state=running&limit=10",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let body = try testJSONDecoder().decode(
                    TaskListResponse.self,
                    from: Data(buffer: response.body),
                )
                #expect(body.tasks.isEmpty)
                #expect(body.nextCursor == nil)
            }
        }
    }

    // MARK: - /v1/insights

    @Test
    func `insights list requires auth`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/insights",
                method: .get,
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `insights list returns empty list and accepts section and limit query params`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/insights?section=this_week&limit=20",
                method: .get,
                headers: [.authorization: "Bearer \(token)"],
            ) { response in
                #expect(response.status == .ok)
                let body = try testJSONDecoder().decode(
                    InsightListResponse.self,
                    from: Data(buffer: response.body),
                )
                #expect(body.insights.isEmpty)
                #expect(body.nextCursor == nil)
            }
        }
    }
}
