import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging
import LuminaVaultShared
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

/// Errors from the Hermes runs gateway contract, mapped to stable HTTP
/// codes by `HermesRunsController`.
enum HermesRunsClientError: Error, Equatable {
    /// `/v1/capabilities` does not report `approval_events` + `run_events_sse`.
    case unsupported
    /// Hermes no longer knows the run (expired from its 300 s store).
    case runNotFound(String)
    /// `POST /approval` while nothing is pending (`approval_not_pending` /
    /// `approval_not_active`).
    case approvalNotPending(String)
    /// Non-2xx that is not one of the above; `code` is Hermes' error code.
    case upstream(status: UInt, code: String?)
    case invalidResponse(String)
    case responseTooLarge(limit: Int)
    /// Stream stalled past the idle timeout.
    case streamIdle(seconds: Double)

    var stableCode: String {
        switch self {
        case .unsupported: "hermes_runs_unsupported"
        case .runNotFound: "hermes_run_expired"
        case .approvalNotPending: "hermes_approval_not_pending"
        case .upstream: "hermes_runs_upstream_error"
        case .invalidResponse: "hermes_runs_invalid_response"
        case .responseTooLarge: "hermes_runs_response_too_large"
        case .streamIdle: "hermes_runs_stream_idle"
        }
    }
}

/// Pollable snapshot from `GET /v1/runs/{id}` (`_set_run_status`).
struct HermesRunStatusSnapshot: Sendable, Equatable {
    let status: String
    let lastEvent: String?
    let output: String?
    let error: String?
    let sessionID: String?

    /// Hermes' status vocabulary → ours. `stopping` stays active until the
    /// gateway confirms `cancelled`.
    var mapped: HermesRunStatus? {
        switch status {
        case "queued": .queued
        case "running", "stopping": .running
        case "waiting_for_approval": .waitingForApproval
        case "completed": .completed
        case "failed": .failed
        case "cancelled", "stopped": .stopped
        default: nil
        }
    }
}

struct HermesRunsCapabilities: Sendable, Equatable {
    let approvalEvents: Bool
    let runEventsSSE: Bool

    var supportsRuns: Bool {
        approvalEvents && runEventsSSE
    }
}

/// Gateway client for `/v1/runs` on the tenant's Hermes (`api_server.py`
/// `_handle_runs`, `_handle_get_run`, `_handle_run_events`,
/// `_handle_run_approval`, `_handle_stop_run`). One instance per resolved
/// endpoint; construct through `HermesRunsClient.make(resolution:…)` so the
/// managed gateway's bearer and a BYO override's auth header are wired the
/// same way as the chat stream (`HermesLLMStreamService.makeStreamRequest`).
struct HermesRunsClient: Sendable {
    let baseURL: URL
    /// Full `Authorization` header value, nil when the gateway is open.
    let authHeader: String?
    /// Optional `X-Hermes-Session-Key` (memory scope on the shared managed
    /// gateway — same header the chat path sends).
    let sessionKey: String?
    let http: any HermesRunsHTTPExecuting
    let logger: Logger
    let requestTimeout: TimeAmount
    /// Hermes writes `: keepalive` every 30 s; anything past this is a stall.
    let streamIdleTimeout: TimeAmount
    let maxResponseBytes: Int

    init(
        baseURL: URL,
        authHeader: String?,
        sessionKey: String? = nil,
        http: any HermesRunsHTTPExecuting,
        logger: Logger,
        requestTimeout: TimeAmount = .seconds(30),
        streamIdleTimeout: TimeAmount = .seconds(120),
        maxResponseBytes: Int = 4 * 1024 * 1024
    ) {
        self.baseURL = baseURL
        self.authHeader = authHeader
        self.sessionKey = sessionKey
        self.http = http
        self.logger = logger
        self.requestTimeout = requestTimeout
        self.streamIdleTimeout = streamIdleTimeout
        self.maxResponseBytes = maxResponseBytes
    }

    /// BYO overrides carry their own full `Authorization` value; the managed
    /// gateway uses the central bearer. Empty key + no override = no header.
    static func make(
        resolution: HermesEndpointResolver.Resolution,
        managedAPIKey: String,
        sessionKey: String?,
        http: any HermesRunsHTTPExecuting,
        logger: Logger
    ) -> HermesRunsClient {
        let auth: String? = if resolution.isUserOverride {
            (resolution.authHeader?.isEmpty == false) ? resolution.authHeader : nil
        } else {
            managedAPIKey.isEmpty ? nil : "Bearer \(managedAPIKey)"
        }
        return HermesRunsClient(
            baseURL: resolution.baseURL,
            authHeader: auth,
            sessionKey: sessionKey,
            http: http,
            logger: logger
        )
    }

    // MARK: - Capabilities

    /// `GET /v1/capabilities` → `features.approval_events` /
    /// `features.run_events_sse`. Both are needed: without approval events
    /// the phone can't act, without SSE the watcher can't follow.
    func capabilities() async throws -> HermesRunsCapabilities {
        let response = try await send(.GET, path: "v1/capabilities")
        guard response.isSuccess else {
            throw HermesRunsClientError.upstream(status: response.status, code: nil)
        }
        let body = try await response.collect(maxBytes: maxResponseBytes)
        return Self.parseCapabilities(Data(buffer: body))
    }

    static func parseCapabilities(_ data: Data) -> HermesRunsCapabilities {
        guard let object = (try? JSONDecoder().decode(AnyJSONValue.self, from: data))?.objectValue else {
            return HermesRunsCapabilities(approvalEvents: false, runEventsSSE: false)
        }
        let features = object["features"]?.objectValue ?? object
        return HermesRunsCapabilities(
            approvalEvents: features["approval_events"]?.boolValue ?? false,
            runEventsSSE: features["run_events_sse"]?.boolValue ?? false
        )
    }

    /// Throws `.unsupported` unless the gateway can run + approve + stream.
    func requireRunsSupport() async throws {
        guard try await capabilities().supportsRuns else {
            throw HermesRunsClientError.unsupported
        }
    }

    // MARK: - Runs

    /// `POST /v1/runs` → 202 `{run_id}`.
    func start(prompt: String, sessionID: String?, model: String?) async throws -> String {
        var body: [String: AnyJSONValue] = ["input": .string(prompt)]
        if let sessionID, !sessionID.isEmpty {
            body["session_id"] = .string(sessionID)
        }
        if let model, !model.isEmpty {
            body["model"] = .string(model)
        }
        let response = try await send(.POST, path: "v1/runs", json: .object(body))
        let object = try await decodeObject(response, operation: "start")
        guard let runID = object["run_id"]?.stringValue, !runID.isEmpty else {
            throw HermesRunsClientError.invalidResponse("run_id missing from POST /v1/runs")
        }
        return runID
    }

    /// `GET /v1/runs/{id}`.
    func status(runID: String) async throws -> HermesRunStatusSnapshot {
        let response = try await send(.GET, path: "v1/runs/\(runID)")
        let object = try await decodeObject(response, operation: "status", runID: runID)
        guard let status = object["status"]?.stringValue else {
            throw HermesRunsClientError.invalidResponse("status missing from GET /v1/runs/\(runID)")
        }
        return HermesRunStatusSnapshot(
            status: status,
            lastEvent: object["last_event"]?.stringValue,
            output: object["output"]?.stringValue,
            error: object["error"]?.stringValue,
            sessionID: object["session_id"]?.stringValue
        )
    }

    /// `POST /v1/runs/{id}/approval` `{choice}`.
    func approve(runID: String, choice: HermesApprovalChoice) async throws {
        let response = try await send(.POST, path: "v1/runs/\(runID)/approval", json: .object(["choice": .string(choice.rawValue)]))
        _ = try await decodeObject(response, operation: "approve", runID: runID)
    }

    /// `POST /v1/runs/{id}/stop`. Hermes answers `stopping`; the
    /// `run.cancelled` event follows on the stream.
    func stop(runID: String) async throws {
        let response = try await send(.POST, path: "v1/runs/\(runID)/stop")
        _ = try await decodeObject(response, operation: "stop", runID: runID)
    }

    /// `GET /v1/runs/{id}/events` as typed frames. Finishes when Hermes
    /// closes the stream (after the terminal event) or throws on a stall /
    /// transport error. Cancelling the consumer cancels the request.
    func events(runID: String) -> AsyncThrowingStream<HermesRunEventFrame, Error> {
        let (stream, continuation) = AsyncThrowingStream<HermesRunEventFrame, Error>.makeStream()
        let client = self
        let work = Task {
            do {
                var request = client.makeRequest(.GET, path: "v1/runs/\(runID)/events")
                request.headers.replaceOrAdd(name: "Accept", value: "text/event-stream")
                let response = try await client.http.execute(request, timeout: client.requestTimeout)
                guard response.isSuccess else {
                    let body = try? await response.collect(maxBytes: client.maxResponseBytes)
                    throw client.mapFailure(status: response.status, body: body, runID: runID)
                }
                try await client.pump(response.body, into: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    private func pump(
        _ body: AsyncThrowingStream<ByteBuffer, Error>,
        into continuation: AsyncThrowingStream<HermesRunEventFrame, Error>.Continuation
    ) async throws {
        let lastActivity = NIOLockedValueBox(NIODeadline.now())
        let idleNanos = streamIdleTimeout.nanoseconds
        let maxBytes = maxResponseBytes * 16
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var parser = SSEFrameParser()
                var total = 0
                for try await chunk in body {
                    try Task.checkCancellation()
                    lastActivity.withLockedValue { $0 = .now() }
                    total += chunk.readableBytes
                    if total > maxBytes {
                        throw HermesRunsClientError.responseTooLarge(limit: maxBytes)
                    }
                    guard let text = chunk.getString(at: chunk.readerIndex, length: chunk.readableBytes) else { continue }
                    for record in parser.feed(text) {
                        if let frame = HermesRunEvent.decode(eventName: record.event, data: record.data) {
                            continuation.yield(frame)
                        }
                    }
                }
                if let record = parser.flush(), let frame = HermesRunEvent.decode(eventName: record.event, data: record.data) {
                    continuation.yield(frame)
                }
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(1))
                    let idle = NIODeadline.now() - lastActivity.withLockedValue { $0 }
                    if idle.nanoseconds > idleNanos {
                        throw HermesRunsClientError.streamIdle(seconds: Double(idleNanos) / 1_000_000_000)
                    }
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Transport helpers

    private func makeRequest(_ method: NIOHTTP1.HTTPMethod, path: String, json: AnyJSONValue? = nil) -> HTTPClientRequest {
        var request = HTTPClientRequest(url: baseURL.appendingPathComponent(path).absoluteString)
        request.method = method
        request.headers.add(name: "Accept", value: "application/json")
        if let authHeader {
            request.headers.add(name: "Authorization", value: authHeader)
        }
        if let sessionKey, !sessionKey.isEmpty {
            request.headers.add(name: "X-Hermes-Session-Key", value: sessionKey)
        }
        if let json, let data = try? JSONEncoder().encode(json) {
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(data)
        }
        return request
    }

    private func send(_ method: NIOHTTP1.HTTPMethod, path: String, json: AnyJSONValue? = nil) async throws -> HermesRunsHTTPResponse {
        try await http.execute(makeRequest(method, path: path, json: json), timeout: requestTimeout)
    }

    private func decodeObject(_ response: HermesRunsHTTPResponse, operation: String, runID: String? = nil) async throws -> [String: AnyJSONValue] {
        let body = try await response.collect(maxBytes: maxResponseBytes)
        guard response.isSuccess else {
            let failure = mapFailure(status: response.status, body: body, runID: runID)
            logger.warning("hermes runs \(operation) failed", metadata: [
                "status": .stringConvertible(response.status),
                "code": .string(failure.stableCode),
            ])
            throw failure
        }
        guard let object = (try? JSONDecoder().decode(AnyJSONValue.self, from: Data(buffer: body)))?.objectValue else {
            throw HermesRunsClientError.invalidResponse("non-object body from \(operation)")
        }
        return object
    }

    /// Hermes error envelope: `{"error": {"message", "code"}}` (`_openai_error`).
    private func mapFailure(status: UInt, body: ByteBuffer?, runID: String?) -> HermesRunsClientError {
        var code: String?
        if let body, let object = (try? JSONDecoder().decode(AnyJSONValue.self, from: Data(buffer: body)))?.objectValue {
            code = object["error"]?.objectValue?["code"]?.stringValue ?? object["code"]?.stringValue
        }
        switch (status, code) {
        case (404, _), (_, "run_not_found"): return .runNotFound(runID ?? "")
        case (409, _), (_, "approval_not_pending"), (_, "approval_not_active"): return .approvalNotPending(runID ?? "")
        default: return .upstream(status: status, code: code)
        }
    }
}
