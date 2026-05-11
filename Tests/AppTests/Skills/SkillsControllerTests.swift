@testable import App
import Configuration
import Hummingbird
import HummingbirdTesting
import Testing

/// HER-148 scaffold smoke test for `POST /v1/skills/:name/run`. The
/// route is registered but the handler is a 501-throwing stub until
/// HER-169 implements `SkillRunner`. The auth-required behavior is
/// covered by the missing-JWT case (401), which is enforced by the
/// `jwtAuthenticator` middleware on the group — independent of HER-169.
struct SkillsControllerTests {
    @Test
    func `unauthenticated request is rejected`() async throws {
        let app = try await buildApplication(reader: noDBTestReader)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/skills/daily-brief/run",
                method: .post,
            ) { response in
                // No Authorization header → 401 from jwtAuthenticator,
                // proves the route is wired and protected.
                #expect(response.status == .unauthorized)
            }
        }
    }
}
