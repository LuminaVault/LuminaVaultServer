@testable import App
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import HummingbirdTesting
import Logging
import LuminaVaultShared
import Testing

/// `/v1/hermes/runs` over the real router, JWT and Postgres. Rows are seeded
/// directly so no route in here dials a Hermes gateway: the outbound paths
/// are covered by `HermesRunsServiceTests` against the fake gateway.
///
/// Requires `docker compose up -d postgres`.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct HermesRunsControllerTests {
    // MARK: - Fixtures

    private static func register(client: some TestClientProtocol) async throws -> (token: String, tenantID: UUID) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let body = ByteBuffer(string: """
        {"email":"runs-\(suffix)@test.luminavault","username":"runs-\(suffix)","password":"CorrectHorseBatteryStaple1!"}
        """)
        return try await client.execute(
            uri: "/v1/auth/register",
            method: .post,
            headers: [.contentType: "application/json"],
            body: body
        ) { response in
            let auth = try testJSONDecoder().decode(AuthResponse.self, from: Data(buffer: response.body))
            return (auth.accessToken, auth.userId)
        }
    }

    /// Seed a finished run plus its events straight into Postgres.
    @discardableResult
    private static func seedRun(
        tenantID: UUID,
        status: HermesRunStatus = .completed,
        events: [(String, AnyJSONValue)] = [],
        pendingApproval: HermesRunPendingApprovalDTO? = nil
    ) async throws -> UUID {
        try await withTestFluent(label: "test.hermes.runs.seed") { fluent in
            let run = HermesRun(
                tenantID: tenantID,
                hermesRunID: "run_\(UUID().uuidString.prefix(8).lowercased())",
                status: status,
                prompt: "seeded run"
            )
            run.summary = status == .completed ? "all done" : nil
            run.pendingApproval = pendingApproval
            run.lastSeq = events.count
            run.lastEvent = events.last?.0
            if status.isTerminal {
                run.finishedAt = Date()
            }
            try await run.save(on: fluent.db())
            let runID = try run.requireID()
            for (index, event) in events.enumerated() {
                try await HermesRunEventRow(
                    runID: runID,
                    seq: index + 1,
                    event: event.0,
                    payload: event.1
                ).save(on: fluent.db())
            }
            return runID
        }
    }

    /// Every `data:` line of an SSE body, decoded.
    private static func decodeSSE(_ buffer: ByteBuffer) throws -> [HermesRunEventDTO] {
        let text = String(buffer: buffer)
        return try text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("data: ") }
            .map { try testJSONDecoder().decode(HermesRunEventDTO.self, from: Data($0.dropFirst(6).utf8)) }
    }

    private static func sseEventNames(_ buffer: ByteBuffer) -> [String] {
        String(buffer: buffer)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("event: ") }
            .map { String($0.dropFirst(7)) }
    }

    // MARK: - Auth

    @Test
    func `every runs route requires a token`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            for (uri, method) in [
                ("/v1/hermes/runs", HTTPRequest.Method.get),
                ("/v1/hermes/runs", .post),
                ("/v1/hermes/runs/\(UUID())", .get),
                ("/v1/hermes/runs/\(UUID())/events", .get),
                ("/v1/hermes/runs/\(UUID())/approval", .post),
                ("/v1/hermes/runs/\(UUID())/stop", .post),
            ] {
                try await client.execute(uri: uri, method: method) { response in
                    #expect(response.status == .unauthorized, "\(method) \(uri)")
                }
            }
        }
    }

    // MARK: - List + get

    @Test
    func `list is empty for a new tenant and shows seeded runs newest first`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, tenantID) = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/hermes/runs",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let list = try testJSONDecoder().decode(HermesRunListResponse.self, from: Data(buffer: response.body))
                #expect(list.runs.isEmpty)
            }

            let first = try await Self.seedRun(tenantID: tenantID)
            let second = try await Self.seedRun(tenantID: tenantID)
            try await client.execute(
                uri: "/v1/hermes/runs?limit=10",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let list = try testJSONDecoder().decode(HermesRunListResponse.self, from: Data(buffer: response.body))
                #expect(Set(list.runs.map(\.id)) == [first, second])
                #expect(list.runs.allSatisfy { $0.status == .completed })
            }
        }
    }

    @Test
    func `get returns the run with its summary and 404s for another tenant's run`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, tenantID) = try await Self.register(client: client)
            let (otherToken, _) = try await Self.register(client: client)
            let runID = try await Self.seedRun(tenantID: tenantID)

            try await client.execute(
                uri: "/v1/hermes/runs/\(runID)",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let run = try testJSONDecoder().decode(HermesRunDTO.self, from: Data(buffer: response.body))
                #expect(run.id == runID)
                #expect(run.summary == "all done")
                #expect(run.status == .completed)
            }

            // Tenant scoping is a 404, never another tenant's data.
            try await client.execute(
                uri: "/v1/hermes/runs/\(runID)",
                method: .get,
                headers: [.authorization: "Bearer \(otherToken)"]
            ) { response in
                #expect(response.status == .notFound)
            }

            try await client.execute(
                uri: "/v1/hermes/runs/\(UUID())",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    // MARK: - SSE replay

    @Test
    func `events replays every persisted event and closes on a terminal run`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, tenantID) = try await Self.register(client: client)
            let runID = try await Self.seedRun(
                tenantID: tenantID,
                events: [
                    ("run.started", .object(["event": .string("run.started")])),
                    ("tool.started", .object(["event": .string("tool.started"), "tool": .string("shell")])),
                    ("run.completed", .object(["event": .string("run.completed"), "output": .string("all done")])),
                ]
            )

            try await client.execute(
                uri: "/v1/hermes/runs/\(runID)/events",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "text/event-stream")
                #expect(Self.sseEventNames(response.body) == Array(repeating: "hermes.run.event", count: 3))
                let events = try Self.decodeSSE(response.body)
                #expect(events.map(\.event) == ["run.started", "tool.started", "run.completed"])
                #expect(events.map(\.seq) == [1, 2, 3])
                #expect(events.allSatisfy { $0.runID == runID })
                // The payload arrives as the real event object, not a string.
                #expect(events.last?.payload.objectValue?["output"]?.stringValue == "all done")
            }
        }
    }

    @Test
    func `events resumes from the after cursor`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, tenantID) = try await Self.register(client: client)
            let runID = try await Self.seedRun(
                tenantID: tenantID,
                events: [
                    ("run.started", .object([:])),
                    ("tool.started", .object([:])),
                    ("run.completed", .object([:])),
                ]
            )

            try await client.execute(
                uri: "/v1/hermes/runs/\(runID)/events?after=2",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let events = try Self.decodeSSE(response.body)
                #expect(events.map(\.seq) == [3])
            }

            // Nothing left after the last seq: an empty, immediately-closed feed.
            try await client.execute(
                uri: "/v1/hermes/runs/\(runID)/events?after=3",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let events = try Self.decodeSSE(response.body)
                #expect(events.isEmpty)
            }
        }
    }

    @Test
    func `events 404s before opening a stream for an unknown run`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, _) = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/hermes/runs/\(UUID())/events",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .notFound)
                #expect(response.headers[.contentType] != "text/event-stream")
            }
        }
    }

    // MARK: - Mutations

    @Test
    func `start rejects an empty prompt without touching hermes`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, _) = try await Self.register(client: client)
            try await client.execute(
                uri: "/v1/hermes/runs",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"prompt":"   "}"#)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test
    func `approval on a run with nothing pending is a conflict`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, tenantID) = try await Self.register(client: client)
            let runID = try await Self.seedRun(tenantID: tenantID, status: .running)

            try await client.execute(
                uri: "/v1/hermes/runs/\(runID)/approval",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"choice":"once"}"#)
            ) { response in
                #expect(response.status == .conflict)
            }

            try await client.execute(
                uri: "/v1/hermes/runs/\(UUID())/approval",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"choice":"deny"}"#)
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func `stopping an already terminal run returns it unchanged`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, tenantID) = try await Self.register(client: client)
            let runID = try await Self.seedRun(tenantID: tenantID)

            try await client.execute(
                uri: "/v1/hermes/runs/\(runID)/stop",
                method: .post,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let run = try testJSONDecoder().decode(HermesRunDTO.self, from: Data(buffer: response.body))
                #expect(run.status == .completed)
            }

            try await client.execute(
                uri: "/v1/hermes/runs/\(UUID())/stop",
                method: .post,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test
    func `a pending approval is serialised to the client`() async throws {
        let app = try await buildApplication(reader: dbTestReader)
        try await app.test(.router) { client in
            let (token, tenantID) = try await Self.register(client: client)
            let runID = try await Self.seedRun(
                tenantID: tenantID,
                status: .waitingForApproval,
                pendingApproval: HermesRunPendingApprovalDTO(
                    command: "rm -rf ***",
                    choices: [.once, .session, .always, .deny],
                    requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    extra: ["tool": .string("shell")]
                )
            )

            try await client.execute(
                uri: "/v1/hermes/runs/\(runID)",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                #expect(response.status == .ok)
                let run = try testJSONDecoder().decode(HermesRunDTO.self, from: Data(buffer: response.body))
                #expect(run.status == .waitingForApproval)
                let pending = try #require(run.pendingApproval)
                #expect(pending.command == "rm -rf ***")
                #expect(pending.choices == HermesApprovalChoice.allCases)
                #expect(pending.extra?["tool"]?.stringValue == "shell")
            }
        }
    }

    // MARK: - Error mapping

    @Test
    func `gateway and service errors map to stable status codes`() {
        #expect(HermesRunsController.status(for: HermesRunsServiceError.runNotFound) == .notFound)
        #expect(HermesRunsController.status(for: HermesRunsServiceError.conversationNotFound) == .notFound)
        #expect(HermesRunsController.status(for: HermesRunsServiceError.tooManyActiveRuns) == .tooManyRequests)
        #expect(HermesRunsController.status(for: HermesRunsServiceError.approvalNotPending) == .conflict)
        #expect(HermesRunsController.status(for: HermesRunsServiceError.runNotActive) == .conflict)
        #expect(HermesRunsController.status(for: HermesRunsServiceError.emptyPrompt) == .badRequest)

        #expect(HermesRunsController.status(for: HermesRunsClientError.unsupported) == .notImplemented)
        #expect(HermesRunsController.status(for: HermesRunsClientError.runNotFound("x")) == .gone)
        #expect(HermesRunsController.status(for: HermesRunsClientError.approvalNotPending("x")) == .conflict)
        #expect(HermesRunsController.status(for: HermesRunsClientError.upstream(status: 500, code: nil)) == .badGateway)
        #expect(HermesRunsController.status(for: HermesRunsClientError.streamIdle(seconds: 1)) == .badGateway)

        #expect(HermesRunsClientError.unsupported.stableCode == "hermes_runs_unsupported")
        #expect(HermesRunsClientError.runNotFound("x").stableCode == "hermes_run_expired")
        #expect(HermesRunsServiceError.tooManyActiveRuns.stableCode == "hermes_runs_limit")
    }
}
