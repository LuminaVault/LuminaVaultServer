@testable import App
import FluentKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import Testing

/// HER-39 — request-level idempotency for mutating endpoints. Verifies
/// replay, body-mismatch detection, cross-tenant isolation, header-absent
/// bypass, and 5xx non-caching behavior.
@Suite(.serialized)
struct IdempotencyMiddlewareTests {
    /// Test-only auth stub: when `x-test-user: <uuid>` is present, attaches a
    /// synthetic `User` so `context.requireTenantID()` succeeds.
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

    private final class CallCounter: @unchecked Sendable {
        var count = 0
    }

    private static func makeApp(fluent: Fluent, counter: CallCounter, responseStatus: HTTPResponse.Status = .ok) -> some ApplicationProtocol {
        let router = Router(context: AppRequestContext.self)
        router.group("/idem")
            .add(middleware: StubAuth())
            .add(middleware: IdempotencyMiddleware(fluent: fluent))
            .post("") { request, _ in
                counter.count += 1
                if responseStatus.code >= 500 {
                    return Response(status: responseStatus)
                }
                var mutable = request
                let buf = try await mutable.collectBody(upTo: 64 * 1024)
                // Echo back the body plus a counter suffix so we can verify
                // which call produced the response.
                let echoed = "\(counter.count):\(buf.readableBytes)"
                return Response(
                    status: responseStatus,
                    headers: [.contentType: "text/plain"],
                    body: .init(byteBuffer: ByteBuffer(string: echoed))
                )
            }
        return Application(router: router)
    }

    @Test
    func `replay returns cached response without re-executing handler`() async throws {
        try await withTestFluent(label: "lv.test.idem.replay") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let counter = CallCounter()
            let user = UUID()
            try await Self.makeApp(fluent: fluent, counter: counter).test(.router) { client in
                let key = UUID()
                let headers: HTTPFields = [
                    .init("x-test-user")!: user.uuidString,
                    .init("Idempotency-Key")!: key.uuidString,
                ]

                var firstBody = ""
                try await client.execute(uri: "/idem", method: .post, headers: headers, body: ByteBuffer(string: "payload")) { response in
                    #expect(response.status == .ok)
                    firstBody = String(buffer: response.body)
                    #expect(response.headers[.init("Idempotent-Replayed")!] == nil)
                }

                try await client.execute(uri: "/idem", method: .post, headers: headers, body: ByteBuffer(string: "payload")) { response in
                    #expect(response.status == .ok)
                    let body = String(buffer: response.body)
                    #expect(body == firstBody)
                    #expect(response.headers[.init("Idempotent-Replayed")!] == "true")
                }

                #expect(counter.count == 1)
            }
        }
    }

    @Test
    func `body change with same key returns 409`() async throws {
        try await withTestFluent(label: "lv.test.idem.mismatch") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let counter = CallCounter()
            let user = UUID()
            try await Self.makeApp(fluent: fluent, counter: counter).test(.router) { client in
                let key = UUID()
                let headers: HTTPFields = [
                    .init("x-test-user")!: user.uuidString,
                    .init("Idempotency-Key")!: key.uuidString,
                ]

                try await client.execute(uri: "/idem", method: .post, headers: headers, body: ByteBuffer(string: "a")) { response in
                    #expect(response.status == .ok)
                }

                try await client.execute(uri: "/idem", method: .post, headers: headers, body: ByteBuffer(string: "b")) { response in
                    #expect(response.status == .conflict)
                }

                #expect(counter.count == 1)
            }
        }
    }

    @Test
    func `same key across different tenants are isolated`() async throws {
        try await withTestFluent(label: "lv.test.idem.tenant") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let counter = CallCounter()
            let userA = UUID()
            let userB = UUID()
            try await Self.makeApp(fluent: fluent, counter: counter).test(.router) { client in
                let sharedKey = UUID()

                try await client.execute(
                    uri: "/idem",
                    method: .post,
                    headers: [
                        .init("x-test-user")!: userA.uuidString,
                        .init("Idempotency-Key")!: sharedKey.uuidString,
                    ],
                    body: ByteBuffer(string: "payload")
                ) { response in
                    #expect(response.status == .ok)
                }

                // Tenant B uses the exact same key. Must NOT replay tenant A's
                // cached response — handler must run a second time.
                try await client.execute(
                    uri: "/idem",
                    method: .post,
                    headers: [
                        .init("x-test-user")!: userB.uuidString,
                        .init("Idempotency-Key")!: sharedKey.uuidString,
                    ],
                    body: ByteBuffer(string: "payload")
                ) { response in
                    #expect(response.status == .ok)
                    #expect(response.headers[.init("Idempotent-Replayed")!] == nil)
                }

                #expect(counter.count == 2)
            }
        }
    }

    @Test
    func `missing idempotency key is a no op`() async throws {
        try await withTestFluent(label: "lv.test.idem.absent") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let counter = CallCounter()
            let user = UUID()
            try await Self.makeApp(fluent: fluent, counter: counter).test(.router) { client in
                let headers: HTTPFields = [.init("x-test-user")!: user.uuidString]

                for _ in 0 ..< 3 {
                    try await client.execute(uri: "/idem", method: .post, headers: headers, body: ByteBuffer(string: "x")) { response in
                        #expect(response.status == .ok)
                    }
                }

                #expect(counter.count == 3)
            }
        }
    }

    @Test
    func `5xx responses are not cached`() async throws {
        try await withTestFluent(label: "lv.test.idem.5xx") { fluent in
            await registerMigrations(on: fluent)
            try await fluent.migrate()

            let counter = CallCounter()
            let user = UUID()
            try await Self.makeApp(fluent: fluent, counter: counter, responseStatus: .internalServerError).test(.router) { client in
                let key = UUID()
                let headers: HTTPFields = [
                    .init("x-test-user")!: user.uuidString,
                    .init("Idempotency-Key")!: key.uuidString,
                ]

                try await client.execute(uri: "/idem", method: .post, headers: headers, body: ByteBuffer(string: "x")) { response in
                    #expect(response.status == .internalServerError)
                }

                try await client.execute(uri: "/idem", method: .post, headers: headers, body: ByteBuffer(string: "x")) { response in
                    #expect(response.status == .internalServerError)
                }

                // Both calls re-executed because the 500 was never cached.
                #expect(counter.count == 2)
            }
        }
    }
}
