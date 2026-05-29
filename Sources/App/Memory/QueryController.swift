import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

extension QueryResponse: @retroactive ResponseEncodable {}

/// Natural-language query against the user's memories. The non-streaming
/// path is a thin wrapper on top of `HermesMemoryService.search` and
/// keeps a stable URL for the iOS client. HER-37 adds a streaming
/// counterpart at `POST /v1/query/stream` that emits `QueryStreamEvent`s
/// over Server-Sent Events.
struct QueryController {
    let service: HermesMemoryService
    let achievements: AchievementsWorker?
    // HER-37 — streaming dependencies. Optional so existing test wirings
    // that only need the non-streaming `/v1/query` route keep compiling.
    let memories: MemoryRepository?
    let embeddings: (any EmbeddingService)?
    let streamService: (any HermesLLMStreamService)?
    /// HER-37 Slice C — optional. When nil both `/v1/query` and
    /// `/v1/query/stream` emit no follow-ups (back-compat).
    let followUpGenerator: FollowUpGenerator?
    let defaultModel: String
    let logger: Logger

    init(
        service: HermesMemoryService,
        achievements: AchievementsWorker?,
        memories: MemoryRepository? = nil,
        embeddings: (any EmbeddingService)? = nil,
        streamService: (any HermesLLMStreamService)? = nil,
        followUpGenerator: FollowUpGenerator? = nil,
        defaultModel: String = "",
        logger: Logger = Logger(label: "lv.query"),
    ) {
        self.service = service
        self.achievements = achievements
        self.memories = memories
        self.embeddings = embeddings
        self.streamService = streamService
        self.followUpGenerator = followUpGenerator
        self.defaultModel = defaultModel
        self.logger = logger
    }

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: query)
        router.post("/stream", use: queryStream)
    }

    @Sendable
    func query(_ req: Request, ctx: AppRequestContext) async throws -> QueryResponse {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: QueryRequest.self, context: ctx)
        guard !body.query.isEmpty else {
            throw HTTPError(.badRequest, message: "query required")
        }
        let tenantID = try user.requireID()
        let answer = try await service.search(
            tenantID: tenantID,
            sessionKey: tenantID.uuidString,
            query: body.query,
            limit: body.limit ?? 5,
        )
        if let achievements {
            achievements.enqueue(tenantID: tenantID, event: .queryRan)
        }
        let hits = answer.hits.map {
            QueryHitDTO(id: $0.id, content: $0.content, distance: $0.distance, createdAt: $0.createdAt)
        }
        // HER-37 Slice C — best-effort follow-ups. Generator is defensive
        // (returns [] on any failure) so this never bumps the response
        // latency floor by more than one bounded Hermes round-trip.
        let followUps: [String]?
        if let followUpGenerator {
            let ups = await followUpGenerator.generate(
                sessionKey: tenantID.uuidString,
                summary: answer.summary,
                sources: hits,
            )
            followUps = ups.isEmpty ? nil : ups
        } else {
            followUps = nil
        }
        return QueryResponse(summary: answer.summary, hits: hits, followUps: followUps)
    }

    /// HER-37 — streaming counterpart to `query`. Retrieves pgvector
    /// hits up-front (emitted as `.source` events so the client can
    /// render source chips immediately), then proxies LLM token deltas
    /// as `.token` events. Always terminates with a `.done` event;
    /// server-generated follow-ups are emitted just before `done`
    /// (empty array until HER-37 Slice C lands).
    @Sendable
    func queryStream(_ req: Request, ctx: AppRequestContext) async throws -> SSEStreamResponse {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: QueryRequest.self, context: ctx)
        guard !body.query.isEmpty else {
            throw HTTPError(.badRequest, message: "query required")
        }
        guard let memories, let embeddings, let streamService else {
            throw HTTPError(.serviceUnavailable, message: "query streaming not configured on this server")
        }
        let tenantID = try user.requireID()
        let limit = max(1, min(body.limit ?? 5, 25))
        let sessionKey = tenantID.uuidString
        let sessionID = body.sessionID
        let userQuery = body.query

        var log = ctx.logger
        log[metadataKey: "tenant_id"] = .string(tenantID.uuidString)
        log.info("query stream begin", metadata: [
            "query_len": .stringConvertible(userQuery.count),
            "limit": .stringConvertible(limit),
        ])

        // Retrieve up-front. If retrieval itself fails, surface a 502
        // through the normal HTTP path — easier to debug than a
        // partial SSE stream.
        let queryEmbedding = try await loggedStage("query.embed", logger: log) {
            try await embeddings.embed(userQuery, tenantID: tenantID)
        }
        let hits = try await loggedStage("query.search", logger: log) {
            try await memories.semanticSearch(
                tenantID: tenantID,
                queryEmbedding: queryEmbedding,
                limit: limit,
            )
        }
        log.info("query grounding", metadata: ["hits": .stringConvertible(hits.count)])

        if let achievements {
            achievements.enqueue(tenantID: tenantID, event: .queryRan)
        }

        let chatRequest = ChatRequest(
            messages: Self.buildPrompt(query: userQuery, hits: hits),
            model: defaultModel.isEmpty ? nil : defaultModel,
            temperature: 0.4,
        )
        let chunks = streamService.chatStream(sessionKey: sessionKey, sessionID: sessionID, request: chatRequest)
        let logger = log
        let followUpGenerator = followUpGenerator
        let hitDTOs = hits.map {
            QueryHitDTO(id: $0.id, content: $0.content, distance: $0.distance, createdAt: $0.createdAt)
        }

        let events = AsyncThrowingStream<QueryStreamEvent, Error> { continuation in
            let task = Task {
                var assistantBuffer = ""

                // 1. Source events — emit before any token so the client
                //    can render the "Based on N notes" provenance row.
                for dto in hitDTOs {
                    continuation.yield(.source(dto))
                }

                // 2. LLM token deltas. HER-252 — attach failover sink so
                //    mid-stream provider transitions surface as a
                //    `.fallback` SSE event the client can banner.
                let fallbackSink: @Sendable (ProviderFailoverNotice) -> Void = { notice in
                    continuation.yield(.fallback(notice.wireDTO()))
                }
                do {
                    let streamStart = DispatchTime.now().uptimeNanoseconds
                    var firstTokenMs: Int64?
                    var tokenCount = 0
                    try await FailoverNoticeContext.$sink.withValue(fallbackSink) {
                        for try await chunk in chunks {
                            if Task.isCancelled { break }
                            if !chunk.delta.isEmpty {
                                if firstTokenMs == nil {
                                    firstTokenMs = Int64((DispatchTime.now().uptimeNanoseconds - streamStart) / 1_000_000)
                                    logger.info("query first token", metadata: ["ttft_ms": .stringConvertible(firstTokenMs ?? 0)])
                                }
                                tokenCount += 1
                                assistantBuffer.append(chunk.delta)
                                continuation.yield(.token(chunk.delta))
                            }
                        }
                    }
                    logger.info("query stream complete", metadata: [
                        "tokens": .stringConvertible(tokenCount),
                        "chars": .stringConvertible(assistantBuffer.count),
                        "duration_ms": .stringConvertible(Int64((DispatchTime.now().uptimeNanoseconds - streamStart) / 1_000_000)),
                        "ttft_ms": .stringConvertible(firstTokenMs ?? -1),
                    ])
                } catch {
                    logger.error("query stream upstream failed", metadata: [
                        "error": .string(Logger.redact(String(describing: error))),
                    ])
                    continuation.yield(.error("upstream failure"))
                    continuation.finish()
                    return
                }

                // 3. Server-generated follow-ups (HER-37 Slice C).
                //    Best-effort: generator returns [] on any failure so
                //    it can never abort the parent stream.
                let followUps: [String] = if let followUpGenerator {
                    await followUpGenerator.generate(
                        sessionKey: sessionKey,
                        sessionID: sessionID,
                        summary: assistantBuffer,
                        sources: hitDTOs,
                    )
                } else {
                    []
                }
                continuation.yield(.followUps(followUps))

                // 4. Terminator.
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return SSEStreamResponse(events: events)
    }

    /// Build the prompt that grounds the streaming reply in retrieved
    /// memories. Citations use `[n]` brackets matching the index of the
    /// hit so a future UI pass can resolve them back to the `source`
    /// events. Kept `static` so unit tests can hit it without a full
    /// controller wiring.
    static func buildPrompt(query: String, hits: [MemorySearchResult]) -> [ChatMessage] {
        let context: String = if hits.isEmpty {
            "(no relevant memories were found)"
        } else {
            hits.enumerated().map { offset, hit in
                "[\(offset + 1)] \(hit.content)"
            }.joined(separator: "\n\n")
        }
        let system = """
        You are Lumina, the user's second-brain assistant. Use the
        retrieved memories below to ground your answer. Cite by their
        bracket number when relevant (e.g. "[1]"). Keep the reply concise
        and conversational. If the memories do not cover the question,
        say so plainly rather than inventing detail.

        Retrieved memories:
        \(context)
        """
        return [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: query),
        ]
    }
}
