@testable import App
import Hummingbird
import HummingbirdTesting
import Testing

struct SidecarTokenMiddlewareTests {
    private static func makeApp(expectedToken: String) -> some ApplicationProtocol {
        let router = Router(context: AppRequestContext.self)
        router.group("/v1/gateways/photon")
            .add(middleware: SidecarTokenMiddleware<AppRequestContext>(expectedToken: expectedToken))
            .post("inbound") { _, _ in
                Response(status: .ok)
            }
        return Application(router: router)
    }

    @Test
    func `missing sidecar token is rejected`() async throws {
        let app = Self.makeApp(expectedToken: "shared-secret")
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/gateways/photon/inbound", method: .post) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `wrong sidecar token is rejected`() async throws {
        let app = Self.makeApp(expectedToken: "shared-secret")
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/gateways/photon/inbound",
                method: .post,
                headers: [.init("x-lumina-sidecar-token")!: "not-the-secret"]
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test
    func `sidecar token header is accepted`() async throws {
        let app = Self.makeApp(expectedToken: "shared-secret")
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/gateways/photon/inbound",
                method: .post,
                headers: [.init("x-lumina-sidecar-token")!: "shared-secret"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test
    func `bearer sidecar token is accepted`() async throws {
        let app = Self.makeApp(expectedToken: "shared-secret")
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/gateways/photon/inbound",
                method: .post,
                headers: [.authorization: "Bearer shared-secret"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test
    func `empty configured sidecar token disables webhook`() async throws {
        let app = Self.makeApp(expectedToken: "")
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/gateways/photon/inbound",
                method: .post,
                headers: [.init("x-lumina-sidecar-token")!: "anything"]
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
