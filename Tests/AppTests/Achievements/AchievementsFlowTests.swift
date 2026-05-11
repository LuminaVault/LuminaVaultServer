@testable import App
import Configuration
import Hummingbird
import HummingbirdTesting
import Testing

/// HER-196 — HTTP-level smoke tests for `/v1/achievements`. Proves the
/// route group is wired and protected by `jwtAuthenticator`. The full
/// `register → upsert N memories → GET shows progress + unlock` flow
/// needs the live Postgres harness (see `AchievementsServiceTests` for
/// the service-layer pieces) and lands once HER-196 ships the bundled
/// auth harness; tracked alongside the iOS bundle.
struct AchievementsFlowTests {
    @Test
    func `list endpoint rejects unauthenticated request`() async throws {
        let app = try await buildApplication(reader: noDBTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/achievements",
                method: .get,
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `recent endpoint rejects unauthenticated request`() async throws {
        let app = try await buildApplication(reader: noDBTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/achievements/recent",
                method: .get,
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }
}
