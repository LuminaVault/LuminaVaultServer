@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

/// HER-94: per-user rate-limit keying. Verifies that the `userOrIPKey`
/// keyer keeps two tenants behind the same NAT in separate buckets, while
/// still degrading to a per-IP bucket when no identity is attached.
struct RateLimitMiddlewareTests {
    private actor StreamGate {
        private var entered = false
        private var released = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func enterAndWait() async {
            entered = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }

            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { continuation in
                enteredWaiters.append(continuation)
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    /// Test-only auth stub: when `x-test-user: <uuid>` is present, attaches
    /// a synthetic `User` to the request context so the rate-limit
    /// middleware sees an `identity`. No header → identity stays nil and
    /// the keyer falls back to IP.
    private struct StubAuth: RouterMiddleware {
        typealias Context = AppRequestContext
        func handle(
            _ request: Request,
            context: Context,
            next: (Request, Context) async throws -> Response
        ) async throws -> Response {
            var ctx = context
            if let raw = request.headers[.init("x-test-user")!],
               let uuid = UUID(uuidString: raw)
            {
                ctx.identity = User(
                    id: uuid,
                    email: "u-\(uuid.uuidString.prefix(6))@test",
                    username: "u\(uuid.uuidString.prefix(6))",
                    passwordHash: ""
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
            keyBuilder: RateLimitPolicy.userOrIPKey
        )
        let router = Router(context: AppRequestContext.self)
        router.group("/limited")
            .add(middleware: StubAuth())
            .add(middleware: RateLimitMiddleware(policy: policy, storage: storage))
            .post("") { _, _ in Response(status: .ok) }
        return Application(router: router)
    }

    private static func makeQueryStreamApp(gate: StreamGate) -> some ApplicationProtocol {
        let router = Router(context: AppRequestContext.self)
        router.group("/v1/query")
            .add(middleware: StubAuth())
            .add(middleware: InFlightLimitMiddleware(maxConcurrent: 1))
            .post("/stream") { _, _ in
                await gate.enterAndWait()
                return Response(status: .ok)
            }
        return Application(router: router)
    }

    private static func makeConversationStreamApp(gate: StreamGate) -> some ApplicationProtocol {
        let router = Router(context: AppRequestContext.self)
        router.group("/v1/conversations")
            .add(middleware: StubAuth())
            .add(middleware: InFlightLimitMiddleware(maxConcurrent: 1))
            .post("/:id/messages/stream") { _, _ in
                await gate.enterAndWait()
                return Response(status: .ok)
            }
        return Application(router: router)
    }

    private static func assertSecondConcurrentRequestIsRejected(
        app: some ApplicationProtocol,
        gate: StreamGate,
        uri: String
    ) async throws {
        try await app.test(.router) { client in
            let userID = UUID()
            let headers: HTTPFields = [
                .init("x-test-user")!: userID.uuidString,
                .init("x-real-ip")!: "10.9.8.7",
            ]

            async let first: Void = client.execute(
                uri: uri,
                method: .post,
                headers: headers
            ) { response in
                #expect(response.status == .ok)
            }

            await gate.waitUntilEntered()

            try await client.execute(
                uri: uri,
                method: .post,
                headers: headers
            ) { response in
                #expect(response.status == .tooManyRequests)
            }

            await gate.release()
            try await first
        }
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
                    ]
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
                ]
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
                ]
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
                    headers: [.init("x-real-ip")!: ip]
                ) { response in
                    #expect(response.status == .ok)
                }
            }

            try await client.execute(
                uri: "/limited",
                method: .post,
                headers: [.init("x-real-ip")!: ip]
            ) { response in
                #expect(response.status == .tooManyRequests)
            }

            // A different anon IP must have its own bucket.
            try await client.execute(
                uri: "/limited",
                method: .post,
                headers: [.init("x-real-ip")!: "5.6.7.8"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test
    func `query policy uses the per user keyer`() {
        #expect(RateLimitPolicy.queryByUser.max == RateLimitPolicy.chatByUser.max)
        #expect(RateLimitPolicy.queryByUser.window == RateLimitPolicy.chatByUser.window)
    }

    @Test
    func `query stream rejects a second concurrent stream for the same user`() async throws {
        let gate = StreamGate()
        try await Self.assertSecondConcurrentRequestIsRejected(
            app: Self.makeQueryStreamApp(gate: gate),
            gate: gate,
            uri: "/v1/query/stream"
        )
    }

    @Test
    func `conversation stream rejects a second concurrent stream for the same user`() async throws {
        let gate = StreamGate()
        let conversationID = UUID()
        try await Self.assertSecondConcurrentRequestIsRejected(
            app: Self.makeConversationStreamApp(gate: gate),
            gate: gate,
            uri: "/v1/conversations/\(conversationID)/messages/stream"
        )
    }
}
