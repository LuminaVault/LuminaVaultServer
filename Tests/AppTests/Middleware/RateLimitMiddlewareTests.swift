@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

/// HER-94: per-user rate-limit keying. Verifies that the `userOrIPKey`
/// keyer keeps two tenants behind the same NAT in separate buckets, while
/// still degrading to a per-IP bucket when no identity is attached.
struct RateLimitMiddlewareTests {
    /// Test-only auth stub: when `x-test-user: <uuid>` is present, attaches
    /// a synthetic `User` to the request context so the rate-limit
    /// middleware sees an `identity`. No header → identity stays nil and
    /// the keyer falls back to IP.
    private struct StubAuth: RouterMiddleware {
        typealias Context = AppRequestContext
        func handle(
            _ request: Request,
            context: Context,
            next: (Request, Context) async throws -> Response,
        ) async throws -> Response {
            var ctx = context
            if let raw = request.headers[.init("x-test-user")!],
               let uuid = UUID(uuidString: raw)
            {
                ctx.identity = User(
                    id: uuid,
                    email: "u-\(uuid.uuidString.prefix(6))@test",
                    username: "u\(uuid.uuidString.prefix(6))",
                    passwordHash: "",
                )
            }
            return try await next(request, ctx)
        }
    }

    private static func makeApp(max: Int) -> some ApplicationProtocol {
        let storage = MemoryPersistDriver()
        let policy = RateLimitPolicy(
            max: max,
            window: 60,
            keyBuilder: RateLimitPolicy.userOrIPKey,
        )
        let router = Router(context: AppRequestContext.self)
        router.group("/limited")
            .add(middleware: StubAuth())
            .add(middleware: RateLimitMiddleware(policy: policy, storage: storage))
            .post("") { _, _ in Response(status: .ok) }
        return Application(router: router)
    }

    @Test
    func `per user buckets are isolated behind shared IP`() async throws {
        let app = Self.makeApp(max: 2)
        try await app.test(.router) { client in
            let userA = UUID()
            let userB = UUID()
            let sharedIP = "10.0.0.1"

            // userA consumes its full per-user budget on the shared NAT IP.
            for _ in 0 ..< 2 {
                try await client.execute(
                    uri: "/limited",
                    method: .post,
                    headers: [
                        .init("x-test-user")!: userA.uuidString,
                        .init("x-real-ip")!: sharedIP,
                    ],
                ) { response in
                    #expect(response.status == .ok)
                }
            }

            // userA is now over budget.
            try await client.execute(
                uri: "/limited",
                method: .post,
                headers: [
                    .init("x-test-user")!: userA.uuidString,
                    .init("x-real-ip")!: sharedIP,
                ],
            ) { response in
                #expect(response.status == .tooManyRequests)
            }

            // userB on the SAME IP must still have a fresh bucket — this is
            // the whole point of per-user keying.
            try await client.execute(
                uri: "/limited",
                method: .post,
                headers: [
                    .init("x-test-user")!: userB.uuidString,
                    .init("x-real-ip")!: sharedIP,
                ],
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test
    func `falls back to per IP when identity missing`() async throws {
        let app = Self.makeApp(max: 2)
        try await app.test(.router) { client in
            let ip = "1.2.3.4"

            // No x-test-user header → ctx.identity is nil → keyer uses IP.
            for _ in 0 ..< 2 {
                try await client.execute(
                    uri: "/limited",
                    method: .post,
                    headers: [.init("x-real-ip")!: ip],
                ) { response in
                    #expect(response.status == .ok)
                }
            }

            try await client.execute(
                uri: "/limited",
                method: .post,
                headers: [.init("x-real-ip")!: ip],
            ) { response in
                #expect(response.status == .tooManyRequests)
            }

            // A different anon IP must have its own bucket.
            try await client.execute(
                uri: "/limited",
                method: .post,
                headers: [.init("x-real-ip")!: "5.6.7.8"],
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }
}
