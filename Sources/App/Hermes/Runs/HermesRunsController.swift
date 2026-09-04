import Foundation
import HTTPTypes
import Hummingbird
import Logging
import LuminaVaultShared

extension HermesRunDTO: @retroactive ResponseEncodable {}
extension HermesRunListResponse: @retroactive ResponseEncodable {}

/// Phase 1 — `/v1/hermes/runs`. Start an agent run on the tenant's Hermes,
/// list and read runs, follow one live, answer its approval prompts and
/// stop it.
///
/// Mounted behind `JWTAuthenticator` + `HermesResolutionMiddleware` (the
/// service resolves the endpoint itself, but the middleware also binds the
/// task-local the rest of the Hermes stack reads) +
/// `EntitlementMiddleware(requires: .chat)`.
///
/// Every route reads the persisted copy: LuminaVault owns run history
/// because the Hermes gateway keeps runs in memory for 300 s only.
struct HermesRunsController {
    /// Rows fetched per replay round-trip on the SSE feed.
    static let eventPageSize = 200
    /// Backstop re-read cadence for the SSE feed. Live updates arrive on the
    /// `EventBus`, which drops the oldest event under backpressure; this tick
    /// guarantees a slow consumer still converges.
    static let feedPollInterval: Duration = .seconds(5)

    let service: HermesRunsService
    let eventBus: EventBus
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: start)
        router.get("", use: list)
        router.get("/:id", use: get)
        router.get("/:id/events", use: events)
        router.post("/:id/approval", use: approve)
        router.post("/:id/stop", use: stop)
    }

    // MARK: - Commands

    /// `POST /v1/hermes/runs` — 202 with the persisted run. Returns as soon
    /// as Hermes has accepted the run; the watcher follows it from there.
    @Sendable
    func start(_ req: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try ctx.requireTenantID()
        let body = try await req.decode(as: HermesRunStartRequest.self, context: ctx)
        let run = try await withMappedErrors {
            try await service.start(tenantID: tenantID, request: body, sessionKey: ctx.activeHermesSessionKey)
        }
        var response = try run.response(from: req, context: ctx)
        response.status = .accepted
        return response
    }

    /// `POST /v1/hermes/runs/:id/approval` — forwards the choice to Hermes
    /// and clears the pending approval.
    @Sendable
    func approve(_ req: Request, ctx: AppRequestContext) async throws -> HermesRunDTO {
        let tenantID = try ctx.requireTenantID()
        let runID = try ctx.parameters.require("id", as: UUID.self)
        let body = try await req.decode(as: HermesRunApprovalRequest.self, context: ctx)
        return try await withMappedErrors {
            try await service.approve(tenantID: tenantID, runID: runID, choice: body.choice)
        }
    }

    /// `POST /v1/hermes/runs/:id/stop`. Hermes answers `stopping`; the
    /// terminal state lands via the watcher, so the returned DTO may still
    /// read `running`.
    @Sendable
    func stop(_: Request, ctx: AppRequestContext) async throws -> HermesRunDTO {
        let tenantID = try ctx.requireTenantID()
        let runID = try ctx.parameters.require("id", as: UUID.self)
        return try await withMappedErrors {
            try await service.stop(tenantID: tenantID, runID: runID)
        }
    }

    // MARK: - Queries

    /// `GET /v1/hermes/runs?limit=` — newest first, capped at 50.
    @Sendable
    func list(_ req: Request, ctx: AppRequestContext) async throws -> HermesRunListResponse {
        let tenantID = try ctx.requireTenantID()
        let limit = req.uri.queryParameters["limit"].flatMap { Int($0) } ?? 20
        return try await withMappedErrors {
            try await HermesRunListResponse(runs: service.list(tenantID: tenantID, limit: limit))
        }
    }

    /// `GET /v1/hermes/runs/:id`.
    @Sendable
    func get(_: Request, ctx: AppRequestContext) async throws -> HermesRunDTO {
        let tenantID = try ctx.requireTenantID()
        let runID = try ctx.parameters.require("id", as: UUID.self)
        return try await withMappedErrors {
            try await service.get(tenantID: tenantID, runID: runID)
        }
    }

    /// `GET /v1/hermes/runs/:id/events?after=<seq>` — SSE, replay then live.
    ///
    /// Persisted events with `seq > after` are written first, so a client
    /// that reconnects with the `lastSeq` it already has never loses an
    /// event and never sees one twice. The feed then follows the `EventBus`
    /// and closes once the run is terminal and fully drained.
    @Sendable
    func events(_ req: Request, ctx: AppRequestContext) async throws -> EncodableSSEStreamResponse<HermesRunEventDTO> {
        let tenantID = try ctx.requireTenantID()
        let runID = try ctx.parameters.require("id", as: UUID.self)
        let after = req.uri.queryParameters["after"].flatMap { Int($0) } ?? 0
        // 404 before a single byte of the stream is written.
        _ = try await withMappedErrors { try await service.get(tenantID: tenantID, runID: runID) }
        return EncodableSSEStreamResponse(
            events: feed(tenantID: tenantID, runID: runID, after: after),
            eventName: "hermes.run.event"
        )
    }

    /// Replay-then-live producer. The wake stream merges `EventBus`
    /// notifications for this run with a slow backstop tick; every wake
    /// re-reads from the cursor, so a dropped bus event only delays an
    /// event, it never loses one.
    func feed(tenantID: UUID, runID: UUID, after: Int) -> AsyncThrowingStream<HermesRunEventDTO, Error> {
        let (stream, continuation) = AsyncThrowingStream<HermesRunEventDTO, Error>.makeStream()
        let service = service
        let eventBus = eventBus
        let logger = logger
        let task = Task {
            let (wake, wakeContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            // Subscribe before the first read so an event persisted between
            // the replay query and the subscription still wakes the drain.
            let bus = eventBus.subscribe(eventType: .hermesRunEvent)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await event in bus {
                        guard let payload = HermesRunEventPayload(event), payload.runID == runID else { continue }
                        wakeContinuation.yield(())
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: Self.feedPollInterval)
                        } catch {
                            return
                        }
                        wakeContinuation.yield(())
                    }
                }
                group.addTask {
                    defer { wakeContinuation.finish() }
                    var cursor = after
                    var iterator = wake.makeAsyncIterator()
                    while !Task.isCancelled {
                        do {
                            let batch = try await service.events(
                                tenantID: tenantID,
                                runID: runID,
                                afterSeq: cursor,
                                limit: Self.eventPageSize
                            )
                            for dto in batch {
                                continuation.yield(dto)
                                cursor = dto.seq
                            }
                            if batch.count == Self.eventPageSize {
                                // A full page means there is more waiting; read
                                // again before parking on the wake stream.
                                continue
                            }
                            let run = try await service.get(tenantID: tenantID, runID: runID)
                            if run.status.isTerminal, cursor >= run.lastSeq {
                                return
                            }
                        } catch {
                            logger.warning("hermes run feed read failed", metadata: [
                                "run": .string(runID.uuidString),
                                "error": .string(Logger.redact(String(describing: error))),
                            ])
                            continuation.finish(throwing: error)
                            return
                        }
                        guard await iterator.next() != nil else { return }
                    }
                }
                await group.next()
                group.cancelAll()
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - Error mapping

    /// One place that turns service + gateway errors into stable HTTP
    /// codes. Clients switch on the message, never on free text.
    func withMappedErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as HermesRunsServiceError {
            throw HTTPError(Self.status(for: error), message: error.stableCode)
        } catch let error as HermesRunsClientError {
            throw HTTPError(Self.status(for: error), message: error.stableCode)
        }
    }

    static func status(for error: HermesRunsServiceError) -> HTTPResponse.Status {
        switch error {
        case .runNotFound, .conversationNotFound: .notFound
        case .tooManyActiveRuns: .tooManyRequests
        case .approvalNotPending, .runNotActive: .conflict
        case .emptyPrompt: .badRequest
        }
    }

    static func status(for error: HermesRunsClientError) -> HTTPResponse.Status {
        switch error {
        // The tenant's Hermes is too old for `/v1/runs`; a retry cannot help.
        case .unsupported: .notImplemented
        // Hermes expired the run out of its 300 s store.
        case .runNotFound: .gone
        case .approvalNotPending: .conflict
        case .upstream, .invalidResponse, .responseTooLarge, .streamIdle: .badGateway
        }
    }
}
