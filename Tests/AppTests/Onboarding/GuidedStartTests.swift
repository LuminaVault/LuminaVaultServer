@testable import App
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import LuminaVaultShared
import Testing

/// Guided-start ("Get started with Hermie") server contract — see
/// `LuminaVaultShared/docs/guided-start.md`.
///
/// Two things are under test here, and they are the two the contract is
/// built on:
///
///   * **Dismissal is two-way.** `guidedStartDismissedAt` round-trips
///     through `GET`, `PATCH {guidedStartDismissed:true}` stamps it and
///     `{false}` clears it. It is the sole exception on an endpoint whose
///     other seven fields still reject `false`.
///   * **Completion is the server's word.** The client never PATCHes the
///     three step latches; the real work flips them. A client's idea of
///     "saved" is not the server's — iOS queues captures offline and
///     drains them later — so the latch is the only trustworthy signal.
///
/// Run with `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct GuidedStartTests {
    private static let testPassword = "CorrectHorseBatteryStaple1!"

    private static func randomUser() -> (email: String, username: String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return ("guided-\(suffix)@test.luminavault", "guided-\(suffix)")
    }

    private static func auth(_ token: String) -> HTTPFields {
        [.authorization: "Bearer \(token)", .contentType: "application/json"]
    }

    private static func registerFull(
        client: some TestClientProtocol
    ) async throws -> (token: String, tenantID: UUID) {
        let (email, username) = randomUser()
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: """
            {"email":"\(email)","username":"\(username)","password":"\(testPassword)"}
            """)
        ) { resp in
            #expect(resp.status == .ok)
            let auth = try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: resp.body))
            // A personal tenant's vault id equals the user id, so this is
            // the tenant id every latch is keyed on.
            return (auth.accessToken, auth.userId)
        }
    }

    private static func register(client: some TestClientProtocol) async throws -> String {
        try await registerFull(client: client).token
    }

    private static func decode(_ buffer: ByteBuffer) throws -> OnboardingStateDTO {
        try testJSONDecoder().decode(OnboardingStateDTO.self, from: Data(buffer: buffer))
    }

    private static func onboarding(
        client: some TestClientProtocol,
        token: String
    ) async throws -> OnboardingStateDTO {
        try await client.execute(
            uri: "/v1/onboarding",
            method: .get,
            headers: [.authorization: "Bearer \(token)"]
        ) { resp in
            #expect(resp.status == .ok)
            return try decode(resp.body)
        }
    }

    @discardableResult
    private static func patch(
        client: some TestClientProtocol,
        token: String,
        json: String,
        expecting status: HTTPResponse.Status = .ok
    ) async throws -> OnboardingStateDTO? {
        try await client.execute(
            uri: "/v1/onboarding",
            method: .patch,
            headers: auth(token),
            body: ByteBuffer(string: json)
        ) { resp in
            #expect(resp.status == status)
            return status == .ok ? try decode(resp.body) : nil
        }
    }

    // MARK: - Dismissal

    @Test
    func `guidedStartDismissedAt round-trips through GET and starts nil`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            // A fresh account is all-false and undismissed, which is what
            // makes the card auto-show. There is no "has seen it" flag.
            let state = try await Self.onboarding(client: client, token: token)
            #expect(state.guidedStartDismissedAt == nil)
            #expect(state.firstCaptureCompleted == false)
            #expect(state.firstKBCompileCompleted == false)
            #expect(state.firstQueryCompleted == false)

            try await Self.patch(client: client, token: token, json: #"{"guidedStartDismissed":true}"#)
            let after = try await Self.onboarding(client: client, token: token)
            #expect(after.guidedStartDismissedAt != nil)
        }
    }

    @Test
    func `patch guidedStartDismissed true stamps the timestamp`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let dismissed = try await Self.patch(
                client: client,
                token: token,
                json: #"{"guidedStartDismissed":true}"#
            )
            #expect(dismissed?.guidedStartDismissedAt != nil)
        }
    }

    @Test
    func `patch guidedStartDismissed false clears the timestamp`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await Self.patch(client: client, token: token, json: #"{"guidedStartDismissed":true}"#)
            // Settings > "Show me around" — the one field on this endpoint
            // that accepts `false` instead of returning 400.
            let cleared = try await Self.patch(
                client: client,
                token: token,
                json: #"{"guidedStartDismissed":false}"#
            )
            #expect(cleared?.guidedStartDismissedAt == nil)
            let refetched = try await Self.onboarding(client: client, token: token)
            #expect(refetched.guidedStartDismissedAt == nil)
        }
    }

    @Test
    func `dismissing twice keeps the original timestamp`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let first = try await Self.patch(
                client: client,
                token: token,
                json: #"{"guidedStartDismissed":true}"#
            )
            try await Task.sleep(nanoseconds: 1_100_000_000)
            let second = try await Self.patch(
                client: client,
                token: token,
                json: #"{"guidedStartDismissed":true}"#
            )
            #expect(second?.guidedStartDismissedAt == first?.guidedStartDismissedAt)
        }
    }

    @Test
    func `the seven latches still reject false`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let latches = [
                "signupCompleted",
                "emailVerifiedCompleted",
                "soulConfiguredCompleted",
                "firstCaptureCompleted",
                "firstKBCompileCompleted",
                "firstQueryCompleted",
                "brainConfiguredCompleted",
            ]
            for field in latches {
                try await Self.patch(
                    client: client,
                    token: token,
                    json: #"{"\#(field)":false}"#,
                    expecting: .badRequest
                )
            }
            // And the exception is genuinely an exception: the same request
            // shape with the dismissal field is a 200, not a 400.
            try await Self.patch(client: client, token: token, json: #"{"guidedStartDismissed":false}"#)
        }
    }

    // MARK: - Step 1: the server latches the capture

    @Test
    func `a vault upload latches firstCaptureCompleted`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            #expect(try await Self.onboarding(client: client, token: token).firstCaptureCompleted == false)

            try await client.execute(
                uri: "/v1/vault/files?path=notes/first.md",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "text/markdown"],
                body: ByteBuffer(string: "# my first memory")
            ) { resp in
                #expect(resp.status == .ok || resp.status == .created)
            }

            // Note the client sent no onboarding PATCH at any point.
            let state = try await Self.onboarding(client: client, token: token)
            #expect(state.firstCaptureCompleted == true)
            #expect(state.firstCaptureCompletedAt != nil)
        }
    }

    @Test
    func `a second upload does not move the firstCapture timestamp`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            for name in ["one.md", "two.md"] {
                try await client.execute(
                    uri: "/v1/vault/files?path=notes/\(name)",
                    method: .post,
                    headers: [.authorization: "Bearer \(token)", .contentType: "text/markdown"],
                    body: ByteBuffer(string: "# \(name)")
                ) { resp in #expect(resp.status == .ok || resp.status == .created) }
                if name == "one.md" { try await Task.sleep(nanoseconds: 1_100_000_000) }
            }
            let state = try await Self.onboarding(client: client, token: token)
            #expect(state.firstCaptureCompleted == true)
            // The latch is idempotent: "first" means first, not latest.
            #expect(state.firstCaptureCompletedAt.map { Date().timeIntervalSince($0) > 1 } == true)
        }
    }

    // MARK: - Step 2: an empty compile is not a compile

    @Test
    func `an empty compile leaves firstKBCompileCompleted false`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/memory-compile",
                method: .post,
                headers: Self.auth(token),
                // `forceFullRecompile` is non-optional on the wire, so `{}`
                // would be a 400 before the controller ever runs.
                body: ByteBuffer(string: #"{"forceFullRecompile":false}"#)
            ) { resp in #expect(resp.status == .ok) }

            // INTENDED, and the reason step 2 needs a client-side guard:
            // the controller returns early when nothing is pending, so the
            // latch never flips. A wizard that started step 2 with an empty
            // vault would poll a flag that cannot move until the five-minute
            // timeout — a silent dead end. `docs/guided-start.md` requires
            // the client to re-read the pending count before starting.
            let state = try await Self.onboarding(client: client, token: token)
            #expect(state.firstKBCompileCompleted == false)
            #expect(state.firstKBCompileCompletedAt == nil)
        }
    }

    // MARK: - Step 3: the server latches the answered question

    /// The deterministic half of step 3: the latch itself, driven directly,
    /// with no LLM in the way.
    ///
    /// The two HTTP tests below can only assert conditionally — neither the
    /// stub adapter nor the SSE gateway can be made to produce a durable
    /// assistant turn inside `app.test`, and asserting `true` there would
    /// be asserting on the harness rather than the contract. This covers
    /// the flip-and-stamp-once behaviour they cannot.
    @Test
    func `the firstQuery latch flips once and keeps its first timestamp`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, tenantID) = try await Self.registerFull(client: client)
            #expect(try await Self.onboarding(client: client, token: token).firstQueryCompleted == false)

            try await withTestFluent(label: "test.guided.latches") { fluent in
                let latches = OnboardingLatches(
                    fluent: fluent,
                    logger: Logger(label: "test.guided.latches")
                )
                await latches.latch(.firstQuery, tenantID: tenantID)
            }
            let first = try await Self.onboarding(client: client, token: token)
            #expect(first.firstQueryCompleted == true)
            #expect(first.firstQueryCompletedAt != nil)

            try await Task.sleep(nanoseconds: 1_100_000_000)
            try await withTestFluent(label: "test.guided.latches") { fluent in
                let latches = OnboardingLatches(
                    fluent: fluent,
                    logger: Logger(label: "test.guided.latches")
                )
                await latches.latch(.firstQuery, tenantID: tenantID)
            }
            let second = try await Self.onboarding(client: client, token: token)
            #expect(second.firstQueryCompletedAt == first.firstQueryCompletedAt)
        }
    }

    @Test
    func `a completed chat latches firstQueryCompleted`() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            #expect(try await Self.onboarding(client: client, token: token).firstQueryCompleted == false)

            let replied = try await client.execute(
                uri: "/v1/llm/chat",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"messages":[{"role":"user","content":"what did I save?"}]}"#)
            ) { $0.status == .ok }

            // Tied to whether the turn actually completed, not asserted flat
            // at `true`: `/v1/llm/chat` also answers 429 when the usage meter
            // cannot read a budget, and a turn that never happened must not
            // latch. Both directions are the contract.
            let state = try await Self.onboarding(client: client, token: token)
            #expect(state.firstQueryCompleted == replied)
            #expect((state.firstQueryCompletedAt != nil) == replied)
        }
    }

    @Test
    func `a completed chat stream latches firstQueryCompleted`() async throws {
        let app = try await buildApplication(reader: dbTestReaderWithStubChat())
        try await app.test(.router) { client in
            let token = try await Self.register(client: client)
            let convo: ConversationDTO = try await client.execute(
                uri: "/v1/conversations",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"title":"guided"}"#)
            ) { try testJSONDecoder().decode(ConversationDTO.self, from: Data(buffer: $0.body)) }

            try await client.execute(
                uri: "/v1/conversations/\(convo.id)/messages/stream",
                method: .post,
                headers: Self.auth(token),
                body: ByteBuffer(string: #"{"content":"what did I save?"}"#)
            ) { resp in
                // `streamReply` returns the SSE response before the upstream
                // hop, so 200 here says nothing about the turn; the assertion
                // that matters is on the persisted assistant message below.
                #expect(resp.status == .ok)
            }

            // The latch tracks the *persisted* assistant turn, so assert on
            // the same condition the controller does rather than on the SSE
            // body. If the stubbed upstream produced no durable turn, the
            // latch must stay false — that is the contract, not a flake.
            let detail: ConversationDetailResponse = try await client.execute(
                uri: "/v1/conversations/\(convo.id)",
                method: .get,
                headers: Self.auth(token)
            ) { try testJSONDecoder().decode(ConversationDetailResponse.self, from: Data(buffer: $0.body)) }
            let persistedAssistantTurn = detail.messages.contains { $0.role == .assistant }

            let state = try await Self.onboarding(client: client, token: token)
            #expect(state.firstQueryCompleted == persistedAssistantTurn)
            #expect((state.firstQueryCompletedAt != nil) == persistedAssistantTurn)
        }
    }
}
