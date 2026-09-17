@testable import App
import Hummingbird
import HummingbirdTesting
import Testing

struct MetricsSecretMiddlewareTests {
    private static func makeApp(expectedSecret: String) -> some ApplicationProtocol {
        let router = Router(context: AppRequestContext.self)
        router.group("/internal")
            .add(middleware: MetricsSecretMiddleware<AppRequestContext>(expectedSecret: expectedSecret))
            .get("metrics") { _, _ in
                Response(status: .ok)
            }
        return Application(router: router)
    }

    @Test
    func `missing bearer is rejected`() async throws {
        let app = Self.makeApp(expectedSecret: "shared-secret")
        try await app.test(.router) { client in
            try await client.execute(uri: "/internal/metrics", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `wrong bearer is rejected`() async throws {
        let app = Self.makeApp(expectedSecret: "shared-secret")
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/internal/metrics",
                method: .get,
                headers: [.authorization: "Bearer not-the-secret"]
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `bare token without Bearer prefix is rejected`() async throws {
        let app = Self.makeApp(expectedSecret: "shared-secret")
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/internal/metrics",
                method: .get,
                headers: [.authorization: "shared-secret"]
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `correct bearer is accepted`() async throws {
        let app = Self.makeApp(expectedSecret: "shared-secret")
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/internal/metrics",
                method: .get,
                headers: [.authorization: "Bearer shared-secret"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test
    func `empty configured secret disables the route`() async throws {
        let app = Self.makeApp(expectedSecret: "")
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/internal/metrics",
                method: .get,
                headers: [.authorization: "Bearer anything"]
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
