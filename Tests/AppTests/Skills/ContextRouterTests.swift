@testable import App
import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing

/// HER-172 unit tests for the ContextRouter middleware + selector.
/// No DB / no Hermes: catalog and selector are both stubbed so each test
/// pins exactly one behavior.
@Suite(.serialized)
struct ContextRouterTests {

    // MARK: - Stub selector

    /// Records every selection request + returns a canned manifest.
    actor StubSelector: ContextRouterSelector {
        var callCount: Int = 0
        var lastMessage: String?
        var lastManifests: [SkillManifest] = []
        private let canned: SkillManifest?

        init(canned: SkillManifest?) { self.canned = canned }

        func selectSkill(
            for userMessage: String,
            manifests: [SkillManifest],
            timeout _: Duration
        ) async -> SkillManifest? {
            callCount += 1
            lastMessage = userMessage
            lastManifests = manifests
            return canned
        }
    }

    // MARK: - Helpers

    private static func makeManifest(
        name: String,
        description: String,
        body: String = "BODY: \(UUID().uuidString)"
    ) -> SkillManifest {
        SkillManifest(
            source: .builtin,
            name: name,
            description: description,
            allowedTools: [],
            capability: .low,
            schedule: nil,
            onEvent: [],
            outputs: [],
            dailyRunCap: nil,
            body: body
        )
    }

    private static func chatBody(messages: [(String, String)]) -> Data {
        let body = ChatRoutingBody(
            messages: messages.map { ChatRoutingBody.Message(role: $0.0, content: $0.1) },
            model: "stub",
            temperature: 0
        )
        return try! JSONEncoder().encode(body)
    }

    // MARK: - ChatRoutingBody invariants (pure)

    @Test
    func prependsSystemWhenNoSystemPresent() throws {
        let body = ChatRoutingBody(
            messages: [.init(role: "user", content: "hello")],
            model: nil,
            temperature: nil
        )
        let result = body.prependingSystem(content: "INJECTED")
        #expect(result.messages.count == 2)
        #expect(result.messages[0].role == "system")
        #expect(result.messages[0].content == "INJECTED")
        #expect(result.messages[1].role == "user")
    }

    @Test
    func mergesIntoExistingSystem() throws {
        let body = ChatRoutingBody(
            messages: [
                .init(role: "system", content: "BASE"),
                .init(role: "user", content: "hi")
            ],
            model: nil, temperature: nil
        )
        let result = body.prependingSystem(content: "INJECTED")
        #expect(result.messages.count == 2)
        #expect(result.messages[0].role == "system")
        #expect(result.messages[0].content == "INJECTED\n\nBASE")
    }

    @Test
    func latestUserContentWalksBackwards() throws {
        let body = ChatRoutingBody(
            messages: [
                .init(role: "user", content: "old"),
                .init(role: "assistant", content: "..."),
                .init(role: "user", content: "newest")
            ],
            model: nil, temperature: nil
        )
        #expect(body.latestUserContent == "newest")
    }

    // MARK: - Middleware behavior

    @Test
    func disabledUserIsNoOp() async throws {
        let selector = StubSelector(canned: nil)
        let middleware = ContextRouterMiddleware(
            manifestProvider: { _ in [] },
            selectorFactory: { _, _ in selector },
            entitlement: { _ in true },
            logger: Logger(label: "test")
        )

        let router = Router(context: AppRequestContext.self)
        router.add(middleware: ForceIdentityMiddleware(contextRouting: false))
        router.add(middleware: middleware)
        router.post("/probe", use: echoBodyHandler)

        let app = Application(router: router)
        try await app.test(.router) { client in
            let body = ByteBuffer(bytes: Self.chatBody(messages: [("user", "anything")]))
            try await client.execute(
                uri: "/probe",
                method: .post,
                headers: [.contentType: "application/json"],
                body: body
            ) { response in
                #expect(response.status == .ok)
                let echoed = try JSONDecoder().decode(ChatRoutingBody.self, from: Data(buffer: response.body))
                #expect(echoed.messages.count == 1)
                #expect(echoed.messages[0].role == "user")
            }
        }
        let calls = await selector.callCount
        #expect(calls == 0, "disabled users must not consume a selector hit")
    }

    @Test
    func selectorReturningNilLeavesBodyUntouched() async throws {
        // Catalog returns [] today (HER-168 not yet wired), so the
        // middleware short-circuits before calling the selector. This
        // covers the "no skills enabled" path — a frequent runtime state
        // until the catalog implementation lands.
        let selector = StubSelector(canned: nil)
        let middleware = ContextRouterMiddleware(
            manifestProvider: { _ in [] },
            selectorFactory: { _, _ in selector },
            entitlement: { _ in true },
            logger: Logger(label: "test")
        )

        let router = Router(context: AppRequestContext.self)
        router.add(middleware: ForceIdentityMiddleware(contextRouting: true))
        router.add(middleware: middleware)
        router.post("/probe", use: echoBodyHandler)

        let app = Application(router: router)
        try await app.test(.router) { client in
            let body = ByteBuffer(bytes: Self.chatBody(messages: [("user", "what's blocking me?")]))
            try await client.execute(
                uri: "/probe",
                method: .post,
                headers: [.contentType: "application/json"],
                body: body
            ) { response in
                #expect(response.status == .ok)
                let echoed = try JSONDecoder().decode(ChatRoutingBody.self, from: Data(buffer: response.body))
                #expect(echoed.messages.count == 1, "empty catalog → no system message inserted")
            }
        }
        let calls = await selector.callCount
        #expect(calls == 0, "empty catalog must short-circuit before the selector")
    }

    @Test
    func selectorMatchPrependsSystemPrompt() async throws {
        // Hand-crafted catalog with one manifest. Use the
        // `OverrideCatalog` test double so the middleware sees real
        // entries without needing HER-168 to be wired.
        let dailyBrief = Self.makeManifest(
            name: "daily-brief",
            description: "summarise yesterday's themes + today's nudges",
            body: "## daily-brief SKILL BODY"
        )
        let selector = StubSelector(canned: dailyBrief)
        let middleware = ContextRouterMiddleware(
            manifestProvider: { _ in [dailyBrief] },
            selectorFactory: { _, _ in selector },
            entitlement: { _ in true },
            logger: Logger(label: "test")
        )

        let router = Router(context: AppRequestContext.self)
        router.add(middleware: ForceIdentityMiddleware(contextRouting: true))
        router.add(middleware: middleware)
        router.post("/probe", use: echoBodyHandler)

        let app = Application(router: router)
        try await app.test(.router) { client in
            let body = ByteBuffer(bytes: Self.chatBody(messages: [
                ("system", "you are hermes"),
                ("user", "what's blocking me from yesterday?")
            ]))
            try await client.execute(
                uri: "/probe",
                method: .post,
                headers: [.contentType: "application/json"],
                body: body
            ) { response in
                #expect(response.status == .ok)
                let echoed = try JSONDecoder().decode(ChatRoutingBody.self, from: Data(buffer: response.body))
                #expect(echoed.messages.count == 2)
                #expect(echoed.messages[0].role == "system")
                #expect(echoed.messages[0].content.contains("daily-brief SKILL BODY"))
                #expect(echoed.messages[0].content.contains("you are hermes"))
            }
        }
        let calls = await selector.callCount
        #expect(calls == 1)
    }

    @Test
    func entitlementGateBlocksWhenFalse() async throws {
        let dailyBrief = Self.makeManifest(name: "daily-brief", description: "x")
        let selector = StubSelector(canned: dailyBrief)
        let middleware = ContextRouterMiddleware(
            manifestProvider: { _ in [dailyBrief] },
            selectorFactory: { _, _ in selector },
            entitlement: { _ in false },     // gate refuses regardless of flag
            logger: Logger(label: "test")
        )

        let router = Router(context: AppRequestContext.self)
        router.add(middleware: ForceIdentityMiddleware(contextRouting: true))
        router.add(middleware: middleware)
        router.post("/probe", use: echoBodyHandler)

        let app = Application(router: router)
        try await app.test(.router) { client in
            let body = ByteBuffer(bytes: Self.chatBody(messages: [("user", "hi")]))
            try await client.execute(
                uri: "/probe",
                method: .post,
                headers: [.contentType: "application/json"],
                body: body
            ) { response in
                #expect(response.status == .ok)
                let echoed = try JSONDecoder().decode(ChatRoutingBody.self, from: Data(buffer: response.body))
                #expect(echoed.messages.count == 1, "entitlement off → no injection even when flag is on")
            }
        }
        let calls = await selector.callCount
        #expect(calls == 0)
    }
}

// MARK: - Local test doubles

/// Bypasses JWT auth in the unit-test router. Constructs a real `User`
/// row in-memory (not persisted) so the middleware sees a normal identity
/// shape.
private struct ForceIdentityMiddleware: RouterMiddleware {
    typealias Context = AppRequestContext
    let contextRouting: Bool

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        var ctx = context
        let user = User(
            id: UUID(),
            email: "test@luminavault.local",
            username: "test-\(UUID().uuidString.prefix(6).lowercased())",
            passwordHash: "x"
        )
        user.contextRouting = contextRouting
        ctx.identity = user
        return try await next(request, ctx)
    }
}

/// Test handler: echoes the request body verbatim so the suite can
/// observe what the middleware decided to forward.
@Sendable
private func echoBodyHandler(_ req: Request, ctx: AppRequestContext) async throws -> Response {
    var mutable = req
    let buf = try await mutable.collectBody(upTo: 256 * 1024)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    return Response(status: .ok, headers: headers, body: .init(byteBuffer: buf))
}
