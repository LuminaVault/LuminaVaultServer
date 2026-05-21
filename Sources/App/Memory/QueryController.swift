import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

extension QueryResponse: ResponseEncodable {}

struct QueryRequest: Codable {
    let query: String
    let limit: Int?
}

/// Natural-language query against the user's memories. The non-streaming
/// path is a thin wrapper on top of `HermesMemoryService.search` and
/// keeps a stable URL for the iOS client. HER-37 adds a streaming
/// counterpart at `POST /v1/query/stream` that emits `QueryStreamEvent`s
/// over Server-Sent Events.
struct QueryController {
    let service: HermesMemoryService
    let achievements: AchievementsService?
    // HER-37 — streaming dependencies. Optional so existing test wirings
    // that only need the non-streaming `/v1/query` route keep compiling.
    let memories: MemoryRepository?
    let embeddings: (any EmbeddingService)?
    let streamService: (any HermesLLMStreamService)?
    let defaultModel: String
    let logger: Logger

    init(
        service: HermesMemoryService,
        achievements: AchievementsService?,
        memories: MemoryRepository? = nil,
        embeddings: (any EmbeddingService)? = nil,
        streamService: (any HermesLLMStreamService)? = nil,
        defaultModel: String = "",
        logger: Logger = Logger(label: "lv.query"),
    ) {
        self.service = service
        self.achievements = achievements
        self.memories = memories
        self.embeddings = embeddings
        self.streamService = streamService
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
            profileUsername: user.username,
            query: body.query,
            limit: body.limit ?? 5,
        )
        if let achievements {
            Task.detached { await achievements.recordAndPush(tenantID: tenantID, event: .queryRan) }
        }
        let hits = answer.hits.map {
            QueryHitDTO(id: $0.id, content: $0.content, distance: $0.distance, createdAt: $0.createdAt)
        }
        return QueryResponse(summary: answer.summary, hits: hits)
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
        let profileUsername = user.username
        let userQuery = body.query

        // Retrieve up-front. If retrieval itself fails, surface a 502
        // through the normal HTTP path — easier to debug than a
        // partial SSE stream.
        let queryEmbedding = try await embeddings.embed(userQuery)
        let hits = try await memories.semanticSearch(
            tenantID: tenantID,
            queryEmbedding: queryEmbedding,
            limit: limit,
        )

        if let achievements {
            Task.detached { await achievements.recordAndPush(tenantID: tenantID, event: .queryRan) }
        }

        let chatRequest = ChatRequest(
            messages: Self.buildPrompt(query: userQuery, hits: hits),
            model: defaultModel.isEmpty ? nil : defaultModel,
            temperature: 0.4,
        )
        let chunks = streamService.chatStream(profileUsername: profileUsername, request: chatRequest)
        let logger = logger

        let events = AsyncThrowingStream<QueryStreamEvent, Error> { continuation in
            let task = Task {
                // 1. Source events — emit before any token so the client
                //    can render the "Based on N notes" provenance row.
                for hit in hits {
                    continuation.yield(.source(QueryHitDTO(
                        id: hit.id,
                        content: hit.content,
                        distance: hit.distance,
                        createdAt: hit.createdAt,
                    )))
                }

                // 2. LLM token deltas.
                do {
                    for try await chunk in chunks {
                        if Task.isCancelled { break }
                        if !chunk.delta.isEmpty {
                            continuation.yield(.token(chunk.delta))
                        }
                    }
                } catch {
                    logger.error("query stream upstream failed: \(error)")
                    continuation.yield(.error("upstream failure"))
                    continuation.finish()
                    return
                }

                // 3. Server-generated follow-ups. HER-37 Slice C wires
                //    `FollowUpGenerator`; until then emit an empty array
                //    so the wire shape is stable.
                continuation.yield(.followUps([]))

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
