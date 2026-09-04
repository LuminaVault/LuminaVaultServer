@testable import App
import AsyncHTTPClient
import Foundation
import Logging
import LuminaVaultShared
import NIOConcurrencyHelpers
import NIOCore

/// In-memory stand-in for a tenant's Hermes gateway. Serves the five
/// `/v1/runs` endpoints plus `/v1/capabilities` from scripted responses and
/// records every request, so the runs client, watcher and service can be
/// driven end-to-end without a socket.
///
/// `/v1/runs/{id}/events` is served as a live stream: the test pushes SSE
/// text with `emit(...)` and closes it with `finishEvents()`, which is how a
/// real run's approval round-trip is reproduced deterministically.
final class FakeHermesRunsGateway: HermesRunsHTTPExecuting, @unchecked Sendable {
    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        let body: String?
        let authorization: String?
        let sessionKey: String?
    }

    struct StubResponse: Sendable {
        let status: UInt
        let body: String

        init(status: UInt = 200, body: String) {
            self.status = status
            self.body = body
        }
    }

    private struct State {
        var requests: [RecordedRequest] = []
        var responses: [String: StubResponse] = [:]
        var eventContinuation: AsyncThrowingStream<ByteBuffer, Error>.Continuation?
        var eventsRequested = 0
        var eventsStatus: UInt = 200
        var eventsFailureBody = ""
    }

    private let state = NIOLockedValueBox(State())

    // MARK: - Scripting

    /// `key` is `"<METHOD> <path>"`, e.g. `"POST v1/runs"`.
    func stub(_ key: String, _ response: StubResponse) {
        state.withLockedValue { $0.responses[key] = response }
    }

    func stub(_ key: String, json: String, status: UInt = 200) {
        stub(key, StubResponse(status: status, body: json))
    }

    /// Make `GET /v1/runs/{id}/events` fail instead of streaming — the
    /// re-attach case, where Hermes has torn the event queue down.
    func failEvents(status: UInt, body: String) {
        state.withLockedValue {
            $0.eventsStatus = status
            $0.eventsFailureBody = body
        }
    }

    var recorded: [RecordedRequest] {
        state.withLockedValue { $0.requests }
    }

    func requests(matching path: String) -> [RecordedRequest] {
        recorded.filter { $0.path == path }
    }

    var eventsSubscriptionCount: Int {
        state.withLockedValue { $0.eventsRequested }
    }

    // MARK: - Event stream control

    /// Push one raw SSE record (`data: {...}\n\n` is appended for you).
    func emit(_ json: String) {
        let continuation = state.withLockedValue { $0.eventContinuation }
        continuation?.yield(ByteBuffer(string: "data: \(json)\n\n"))
    }

    /// Push arbitrary bytes — used to prove chunk-split framing.
    func emitRaw(_ text: String) {
        let continuation = state.withLockedValue { $0.eventContinuation }
        continuation?.yield(ByteBuffer(string: text))
    }

    func finishEvents() {
        let continuation = state.withLockedValue { state -> AsyncThrowingStream<ByteBuffer, Error>.Continuation? in
            defer { state.eventContinuation = nil }
            return state.eventContinuation
        }
        continuation?.finish()
    }

    /// Suspend until the events endpoint has actually been subscribed, so a
    /// test never emits into a stream nobody is reading yet.
    func waitForEventSubscription(timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if state.withLockedValue({ $0.eventContinuation }) != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        struct Timeout: Error {}
        throw Timeout()
    }

    // MARK: - HermesRunsHTTPExecuting

    func execute(_ request: HTTPClientRequest, timeout _: TimeAmount) async throws -> HermesRunsHTTPResponse {
        let method = request.method.rawValue
        let path = Self.path(of: request.url)
        let record = try await RecordedRequest(
            method: method,
            path: path,
            body: Self.bodyString(request),
            authorization: request.headers.first(name: "Authorization"),
            sessionKey: request.headers.first(name: "X-Hermes-Session-Key")
        )
        state.withLockedValue { $0.requests.append(record) }

        if method == "GET", path.hasSuffix("/events") {
            return openEventStream()
        }
        let stub = state.withLockedValue { $0.responses["\(method) \(path)"] }
            ?? StubResponse(status: 404, body: #"{"error":{"code":"run_not_found"}}"#)
        return HermesRunsHTTPResponse(status: stub.status, body: Self.oneShot(stub.body))
    }

    private func openEventStream() -> HermesRunsHTTPResponse {
        let (status, failureBody) = state.withLockedValue { ($0.eventsStatus, $0.eventsFailureBody) }
        state.withLockedValue { $0.eventsRequested += 1 }
        guard status == 200 else {
            return HermesRunsHTTPResponse(status: status, body: Self.oneShot(failureBody))
        }
        let (stream, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
        state.withLockedValue { $0.eventContinuation = continuation }
        return HermesRunsHTTPResponse(status: 200, body: stream)
    }

    // MARK: - Helpers

    static func oneShot(_ body: String) -> AsyncThrowingStream<ByteBuffer, Error> {
        let (stream, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
        if !body.isEmpty {
            continuation.yield(ByteBuffer(string: body))
        }
        continuation.finish()
        return stream
    }

    /// Path without the leading slash, matching how the client builds URLs.
    static func path(of url: String) -> String {
        guard let components = URLComponents(string: url) else { return url }
        return String(components.path.drop(while: { $0 == "/" }))
    }

    static func bodyString(_ request: HTTPClientRequest) async throws -> String? {
        guard let body = request.body else { return nil }
        var collected = ByteBuffer()
        for try await chunk in body {
            var chunk = chunk
            collected.writeBuffer(&chunk)
        }
        guard collected.readableBytes > 0 else { return nil }
        return collected.getString(at: collected.readerIndex, length: collected.readableBytes)
    }

    // MARK: - Convenience

    static let supportedCapabilities = #"{"features":{"approval_events":true,"run_events_sse":true}}"#

    /// A gateway that accepts a run and reports full runs support.
    static func accepting(runID: String) -> FakeHermesRunsGateway {
        let gateway = FakeHermesRunsGateway()
        gateway.stub("GET v1/capabilities", json: supportedCapabilities)
        gateway.stub("POST v1/runs", json: #"{"run_id":"\#(runID)"}"#, status: 202)
        gateway.stub("POST v1/runs/\(runID)/approval", json: #"{"status":"accepted"}"#)
        gateway.stub("POST v1/runs/\(runID)/stop", json: #"{"status":"stopping"}"#)
        return gateway
    }

    func client(sessionKey: String? = nil) -> HermesRunsClient {
        HermesRunsClient(
            baseURL: URL(string: "http://hermes.test")!,
            authHeader: "Bearer fake-token",
            sessionKey: sessionKey,
            http: self,
            logger: Logger(label: "test.hermes.runs"),
            requestTimeout: .seconds(5),
            streamIdleTimeout: .seconds(30)
        )
    }
}

/// Records the pushes a run produces so the approval and completion
/// notifications can be asserted without APNS or a device-token table.
actor RecordingRunPushNotifier: HermesRunPushNotifying {
    private(set) var approvals: [HermesRunDTO] = []
    private(set) var completions: [HermesRunDTO] = []

    func approvalRequested(tenantID _: UUID, run: HermesRunDTO) async {
        approvals.append(run)
    }

    func runFinished(tenantID _: UUID, run: HermesRunDTO) async {
        completions.append(run)
    }

    /// Suspend until `count` approval pushes have landed.
    func waitForApprovals(_ count: Int, timeout: Duration = .seconds(5)) async throws {
        try await wait(timeout: timeout) { self.approvals.count >= count }
    }

    func waitForCompletions(_ count: Int, timeout: Duration = .seconds(5)) async throws {
        try await wait(timeout: timeout) { self.completions.count >= count }
    }

    private func wait(timeout: Duration, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        struct Timeout: Error {}
        throw Timeout()
    }
}
