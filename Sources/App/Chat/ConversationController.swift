import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

// MARK: - Server-side response conformances

extension ConversationDTO: ResponseEncodable {}
extension ConversationListResponse: ResponseEncodable {}
extension ConversationDetailResponse: ResponseEncodable {}

/// HER-37 — multi-turn chat persistence + streaming assistant turns.
/// Owns `/v1/conversations` (CRUD) and
/// `/v1/conversations/:id/messages/stream` (SSE).
///
/// Persistence semantics for the stream endpoint: the user's message is
/// written immediately (before any upstream call), the assistant's full
/// reply is written exactly once on `done`. If the LLM stream errors
/// mid-flight the assistant turn is NOT persisted — clients see the
/// `.error` event and can retry.
struct ConversationController {
    let fluent: Fluent
    let memories: MemoryRepository
    let embeddings: any EmbeddingService
    let streamService: any HermesLLMStreamService
    /// HER-37 Slice C — optional. When nil the SSE stream emits an empty
    /// `.followUps([])` event for back-compat.
    let followUpGenerator: FollowUpGenerator?
    let defaultModel: String
    let logger: Logger

    init(
        fluent: Fluent,
        memories: MemoryRepository,
        embeddings: any EmbeddingService,
        streamService: any HermesLLMStreamService,
        followUpGenerator: FollowUpGenerator? = nil,
        defaultModel: String,
        logger: Logger,
    ) {
        self.fluent = fluent
        self.memories = memories
        self.embeddings = embeddings
        self.streamService = streamService
        self.followUpGenerator = followUpGenerator
        self.defaultModel = defaultModel
        self.logger = logger
    }

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: create)
        router.get("", use: list)
        router.get("/:id", use: getOne)
        router.delete("/:id", use: delete)
        router.post("/:id/messages/stream", use: streamReply)
    }

    // MARK: - CRUD

    @Sendable
    func create(_ req: Request, ctx: AppRequestContext) async throws -> ConversationDTO {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: ConversationCreateRequest.self, context: ctx)
        let conversation = try Conversation(
            tenantID: user.requireID(),
            title: (body.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "New conversation",
            spaceID: body.spaceId,
        )
        try await conversation.save(on: fluent.db())
        return try conversation.toDTO()
    }

    @Sendable
    func list(_: Request, ctx: AppRequestContext) async throws -> ConversationListResponse {
        let tenantID = try ctx.requireTenantID()
        let rows = try await Conversation.query(on: fluent.db(), tenantID: tenantID)
            .sort(\.$updatedAt, .descending)
            .limit(100)
            .all()
        let dtos = try rows.map { try $0.toDTO() }
        return ConversationListResponse(conversations: dtos, nextCursor: nil)
    }

    @Sendable
    func getOne(_: Request, ctx: AppRequestContext) async throws -> ConversationDetailResponse {
        let id = try Self.parseID(ctx)
        let tenantID = try ctx.requireTenantID()
        let conversation = try await fetch(tenantID: tenantID, id: id)
        let messages = try await ConversationMessage.query(on: fluent.db())
            .filter(\.$conversationID == id)
            .sort(\.$createdAt, .ascending)
            .all()
        return try ConversationDetailResponse(
            conversation: conversation.toDTO(),
            messages: messages.map { try $0.toDTO() },
        )
    }

    @Sendable
    func delete(_: Request, ctx: AppRequestContext) async throws -> Response {
        let id = try Self.parseID(ctx)
        let tenantID = try ctx.requireTenantID()
        let conversation = try await fetch(tenantID: tenantID, id: id)
        try await conversation.delete(on: fluent.db())
        return Response(status: .noContent)
    }

    // MARK: - Streaming reply

    /// Persists the user's message immediately, then opens an SSE stream
    /// that yields `.source` events for retrieved memories, forwarded
    /// `.token` deltas from the LLM, an empty `.followUps([])` (Slice C
    /// populates), and a terminal `.done`. The assistant turn is
    /// persisted on `.done`; errors abort persistence and surface as
    /// `.error` events.
    @Sendable
    func streamReply(_ req: Request, ctx: AppRequestContext) async throws -> SSEStreamResponse {
        let user = try ctx.requireIdentity()
        let conversationID = try Self.parseID(ctx)
        let tenantID = try user.requireID()
        let conversation = try await fetch(tenantID: tenantID, id: conversationID)
        let body = try await req.decode(as: MessageStreamRequest.self, context: ctx)
        let content = body.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw HTTPError(.badRequest, message: "content required")
        }

        // Persist user turn synchronously so the transcript is durable
        // even if the assistant stream fails downstream.
        let userMessage = try ConversationMessage(
            conversationID: conversation.requireID(),
            role: .user,
            content: content,
        )
        try await userMessage.save(on: fluent.db())

        // Load full transcript history so the LLM sees prior turns.
        let history = try await ConversationMessage.query(on: fluent.db())
            .filter(\.$conversationID == conversationID)
            .sort(\.$createdAt, .ascending)
            .all()

        // Retrieve grounding memories on the latest user turn.
        let queryEmbedding = try await embeddings.embed(content)
        let hits = try await memories.semanticSearch(
            tenantID: tenantID,
            queryEmbedding: queryEmbedding,
            limit: 5,
        )

        let chatRequest = ChatRequest(
            messages: Self.buildPrompt(history: history, hits: hits),
            model: defaultModel.isEmpty ? nil : defaultModel,
            temperature: 0.4,
        )
        let sessionKey = tenantID.uuidString
        let sessionID = conversationID.uuidString
        let chunks = streamService.chatStream(sessionKey: sessionKey, sessionID: sessionID, request: chatRequest)
        let fluent = fluent
        let logger = logger
        let followUpGenerator = followUpGenerator
        let sourceIDs = hits.map(\.id)
        let hitDTOs = hits.map {
            QueryHitDTO(id: $0.id, content: $0.content, distance: $0.distance, createdAt: $0.createdAt)
        }

        let events = AsyncThrowingStream<QueryStreamEvent, Error> { continuation in
            let task = Task {
                var assistantBuffer = ""

                for dto in hitDTOs {
                    continuation.yield(.source(dto))
                }

                // HER-252 — attach a failover sink so RoutedLLMTransport
                // can surface mid-stream provider transitions (e.g. Grok
                // credits exhausted → Qwen2.5 via OpenRouter) as a
                // `.fallback` SSE event the client renders as a banner.
                let fallbackSink: @Sendable (ProviderFailoverNotice) -> Void = { notice in
                    continuation.yield(.fallback(notice.wireDTO()))
                }

                do {
                    try await FailoverNoticeContext.$sink.withValue(fallbackSink) {
                        for try await chunk in chunks {
                            if Task.isCancelled { break }
                            if !chunk.delta.isEmpty {
                                assistantBuffer.append(chunk.delta)
                                continuation.yield(.token(chunk.delta))
                            }
                        }
                    }
                } catch {
                    logger.error("conversation stream upstream failed: \(error)")
                    continuation.yield(.error("upstream failure"))
                    continuation.finish()
                    return
                }

                // Persist assistant turn + bump conversation updatedAt.
                // Failures here are logged but not surfaced — the stream
                // already succeeded as far as the client is concerned.
                do {
                    let assistantMessage = ConversationMessage(
                        conversationID: conversationID,
                        role: .assistant,
                        content: assistantBuffer,
                        sourceMemoryIDs: sourceIDs,
                    )
                    try await assistantMessage.save(on: fluent.db())
                    conversation.updatedAt = Date()
                    try await conversation.save(on: fluent.db())
                } catch {
                    logger.error("assistant turn persist failed: \(error)")
                }

                // HER-37 Slice C — best-effort follow-ups, defensive ([]).
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
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return SSEStreamResponse(events: events)
    }

    // MARK: - Helpers

    /// Tenant-scoped fetch. Returns a 404 (instead of 403) when the row
    /// belongs to another tenant — avoids leaking row existence across
    /// tenants.
    private func fetch(tenantID: UUID, id: UUID) async throws -> Conversation {
        guard let conversation = try await Conversation.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == id)
            .first()
        else {
            throw HTTPError(.notFound, message: "conversation not found")
        }
        return conversation
    }

    private static func parseID(_ ctx: AppRequestContext) throws -> UUID {
        guard let raw = ctx.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid conversation id")
        }
        return id
    }

    /// Build the prompt for the streaming reply. Replays the entire
    /// transcript so far (history already includes the just-saved user
    /// turn), prefixed by a Lumina system message that injects grounding
    /// memories with `[n]` citations matching the order of `.source`
    /// events. Kept `static` for unit-test friendliness.
    static func buildPrompt(
        history: [ConversationMessage],
        hits: [MemorySearchResult],
    ) -> [ChatMessage] {
        let context: String = if hits.isEmpty {
            "(no relevant memories were found)"
        } else {
            hits.enumerated().map { offset, hit in
                "[\(offset + 1)] \(hit.content)"
            }.joined(separator: "\n\n")
        }
        let system = ChatMessage(role: "system", content: """
        You are Lumina, the user's second-brain assistant. Use the
        retrieved memories below to ground your answer. Cite by their
        bracket number when relevant (e.g. "[1]"). Keep the reply concise
        and conversational. If the memories do not cover the question,
        say so plainly rather than inventing detail.

        Retrieved memories:
        \(context)
        """)
        let turns = history.map { ChatMessage(role: $0.role, content: $0.content) }
        return [system] + turns
    }
}
