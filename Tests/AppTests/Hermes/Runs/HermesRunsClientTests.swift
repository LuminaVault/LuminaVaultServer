@testable import App
import Foundation
import LuminaVaultShared
import Testing

/// The `/v1/runs` gateway contract, exercised against `FakeHermesRunsGateway`
/// so every wire detail (paths, bodies, headers, error codes, SSE framing) is
/// asserted without a socket.
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct HermesRunsClientTests {
    // MARK: - Capabilities

    @Test
    func `capabilities requires both approval events and run event SSE`() {
        let both = HermesRunsClient.parseCapabilities(Data(FakeHermesRunsGateway.supportedCapabilities.utf8))
        #expect(both.supportsRuns)

        let sseOnly = HermesRunsClient.parseCapabilities(
            Data(#"{"features":{"approval_events":false,"run_events_sse":true}}"#.utf8)
        )
        #expect(sseOnly.runEventsSSE)
        #expect(!sseOnly.supportsRuns)

        let garbage = HermesRunsClient.parseCapabilities(Data("not json".utf8))
        #expect(!garbage.approvalEvents)
        #expect(!garbage.supportsRuns)
    }

    @Test
    func `requireRunsSupport throws unsupported when the gateway lacks the flags`() async throws {
        let gateway = FakeHermesRunsGateway()
        gateway.stub("GET v1/capabilities", json: #"{"features":{"approval_events":false,"run_events_sse":false}}"#)
        await #expect(throws: HermesRunsClientError.unsupported) {
            try await gateway.client().requireRunsSupport()
        }
    }

    // MARK: - Start

    @Test
    func `start posts the prompt and returns the hermes run id`() async throws {
        let gateway = FakeHermesRunsGateway.accepting(runID: "run_abc123")
        let runID = try await gateway.client(sessionKey: "profile:stocks")
            .start(prompt: "audit the vault", sessionID: "sess-1", model: "hermes-3")

        #expect(runID == "run_abc123")
        let request = try #require(gateway.requests(matching: "v1/runs").first)
        #expect(request.method == "POST")
        #expect(request.authorization == "Bearer fake-token")
        #expect(request.sessionKey == "profile:stocks")
        let body = try #require(request.body)
        let decoded = try #require(
            try JSONDecoder().decode(AnyJSONValue.self, from: Data(body.utf8)).objectValue
        )
        #expect(decoded["input"]?.stringValue == "audit the vault")
        #expect(decoded["session_id"]?.stringValue == "sess-1")
        #expect(decoded["model"]?.stringValue == "hermes-3")
    }

    @Test
    func `start omits empty optional fields`() async throws {
        let gateway = FakeHermesRunsGateway.accepting(runID: "run_x")
        _ = try await gateway.client().start(prompt: "go", sessionID: nil, model: "")
        let body = try #require(gateway.requests(matching: "v1/runs").first?.body)
        let decoded = try #require(
            try JSONDecoder().decode(AnyJSONValue.self, from: Data(body.utf8)).objectValue
        )
        #expect(decoded["session_id"] == nil)
        #expect(decoded["model"] == nil)
    }

    @Test
    func `start throws invalidResponse when hermes omits run_id`() async throws {
        let gateway = FakeHermesRunsGateway()
        gateway.stub("POST v1/runs", json: #"{"accepted":true}"#, status: 202)
        await #expect(throws: HermesRunsClientError.self) {
            try await gateway.client().start(prompt: "go", sessionID: nil, model: nil)
        }
    }

    // MARK: - Status

    @Test
    func `status maps the hermes vocabulary onto run statuses`() {
        func snapshot(_ raw: String) -> HermesRunStatus? {
            HermesRunStatusSnapshot(status: raw, lastEvent: nil, output: nil, error: nil, sessionID: nil).mapped
        }
        #expect(snapshot("queued") == .queued)
        #expect(snapshot("running") == .running)
        // `stopping` is still active — only the confirmed cancel is terminal.
        #expect(snapshot("stopping") == .running)
        #expect(snapshot("waiting_for_approval") == .waitingForApproval)
        #expect(snapshot("completed") == .completed)
        #expect(snapshot("failed") == .failed)
        #expect(snapshot("cancelled") == .stopped)
        #expect(snapshot("stopped") == .stopped)
        #expect(snapshot("who-knows") == nil)
    }

    @Test
    func `status reads the run snapshot`() async throws {
        let gateway = FakeHermesRunsGateway()
        gateway.stub(
            "GET v1/runs/run_1",
            json: #"{"status":"completed","last_event":"run.completed","output":"done","session_id":"s1"}"#
        )
        let snapshot = try await gateway.client().status(runID: "run_1")
        #expect(snapshot.mapped == .completed)
        #expect(snapshot.output == "done")
        #expect(snapshot.sessionID == "s1")
    }

    // MARK: - Approval + stop

    @Test
    func `approve posts the chosen answer`() async throws {
        let gateway = FakeHermesRunsGateway.accepting(runID: "run_1")
        try await gateway.client().approve(runID: "run_1", choice: .session)
        let request = try #require(gateway.requests(matching: "v1/runs/run_1/approval").first)
        #expect(request.method == "POST")
        #expect(request.body == #"{"choice":"session"}"#)
    }

    @Test
    func `stop posts to the stop endpoint`() async throws {
        let gateway = FakeHermesRunsGateway.accepting(runID: "run_1")
        try await gateway.client().stop(runID: "run_1")
        #expect(gateway.requests(matching: "v1/runs/run_1/stop").first?.method == "POST")
    }

    @Test
    func `a 404 becomes runNotFound and a 409 becomes approvalNotPending`() async throws {
        let gateway = FakeHermesRunsGateway()
        gateway.stub("POST v1/runs/gone/stop", json: #"{"error":{"code":"run_not_found"}}"#, status: 404)
        gateway.stub(
            "POST v1/runs/busy/approval",
            json: #"{"error":{"code":"approval_not_pending"}}"#,
            status: 409
        )
        await #expect(throws: HermesRunsClientError.runNotFound("gone")) {
            try await gateway.client().stop(runID: "gone")
        }
        await #expect(throws: HermesRunsClientError.approvalNotPending("busy")) {
            try await gateway.client().approve(runID: "busy", choice: .deny)
        }
    }

    @Test
    func `a 500 becomes an upstream error carrying the hermes code`() async throws {
        let gateway = FakeHermesRunsGateway()
        gateway.stub("GET v1/runs/boom", json: #"{"error":{"code":"internal_error"}}"#, status: 500)
        await #expect(throws: HermesRunsClientError.upstream(status: 500, code: "internal_error")) {
            try await gateway.client().status(runID: "boom")
        }
    }

    // MARK: - Event stream

    @Test
    func `events yields typed frames in order and finishes with the stream`() async throws {
        let gateway = FakeHermesRunsGateway.accepting(runID: "run_1")
        let client = gateway.client()

        let collector = Task {
            var frames: [HermesRunEventFrame] = []
            for try await frame in client.events(runID: "run_1") {
                frames.append(frame)
            }
            return frames
        }
        try await gateway.waitForEventSubscription()
        gateway.emit(#"{"event":"run.started","run_id":"run_1"}"#)
        gateway.emitRaw(": keepalive\n\n")
        // Split one record across two chunks to prove the parser buffers.
        gateway.emitRaw("data: {\"event\":\"tool.started\",")
        gateway.emitRaw("\"tool\":\"shell\"}\n\n")
        gateway.emit(#"{"event":"run.completed","output":"all done"}"#)
        gateway.finishEvents()

        let frames = try await collector.value
        #expect(frames.map(\.name) == ["run.started", "tool.started", "run.completed"])
        #expect(frames[1].event == .toolStarted(tool: "shell", preview: nil))
        #expect(frames[2].event == .runCompleted(summary: "all done"))
    }

    @Test
    func `events throws when the gateway rejects the subscription`() async throws {
        let gateway = FakeHermesRunsGateway.accepting(runID: "run_1")
        gateway.failEvents(status: 404, body: #"{"error":{"code":"run_not_found"}}"#)
        await #expect(throws: HermesRunsClientError.runNotFound("run_1")) {
            for try await _ in gateway.client().events(runID: "run_1") {}
        }
    }

    // MARK: - Auth wiring

    @Test
    func `make uses the managed bearer, and a BYO override's own header`() throws {
        let managed = try HermesRunsClient.make(
            resolution: .init(baseURL: #require(URL(string: "http://managed")), authHeader: nil, isUserOverride: false),
            managedAPIKey: "central-key",
            sessionKey: nil,
            http: FakeHermesRunsGateway(),
            logger: .init(label: "t")
        )
        #expect(managed.authHeader == "Bearer central-key")

        let byo = try HermesRunsClient.make(
            resolution: .init(baseURL: #require(URL(string: "http://byo")), authHeader: "Token abc", isUserOverride: true),
            managedAPIKey: "central-key",
            sessionKey: nil,
            http: FakeHermesRunsGateway(),
            logger: .init(label: "t")
        )
        #expect(byo.authHeader == "Token abc")

        let openGateway = try HermesRunsClient.make(
            resolution: .init(baseURL: #require(URL(string: "http://byo")), authHeader: "", isUserOverride: true),
            managedAPIKey: "central-key",
            sessionKey: nil,
            http: FakeHermesRunsGateway(),
            logger: .init(label: "t")
        )
        #expect(openGateway.authHeader == nil)
    }
}
