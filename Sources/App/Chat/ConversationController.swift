import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

// MARK: - Server-side response conformances

extension ConversationDTO: @retroactive ResponseEncodable {}
extension ConversationListResponse: @retroactive ResponseEncodable {}
extension ConversationDetailResponse: @retroactive ResponseEncodable {}
extension ConversationPrepareResponse: @retroactive ResponseEncodable {}
extension ConversationCommitResponse: @retroactive ResponseEncodable {}

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
    /// HER-274 — auto-save-link post-processor dependencies. `nil` when
    /// the global `AUTO_SAVE_LINKS_ENABLED` feature flag is off, in
    /// which case `streamReply` skips URL extraction entirely.
    let linkCapture: LinkCaptureService?
    let urlExtractor: URLExtractionService
    let parallelEnabled: Bool
    let hybridExecutionEnabled: Bool
    let defaultModel: String
    let logger: Logger

    init(
        fluent: Fluent,
        memories: MemoryRepository,
        embeddings: any EmbeddingService,
        streamService: any HermesLLMStreamService,
        followUpGenerator: FollowUpGenerator? = nil,
        linkCapture: LinkCaptureService? = nil,
        urlExtractor: URLExtractionService = URLExtractionService(),
        parallelEnabled: Bool = false,
        hybridExecutionEnabled: Bool = false,
        defaultModel: String,
        logger: Logger
    ) {
        self.fluent = fluent
        self.memories = memories
        self.embeddings = embeddings
        self.streamService = streamService
        self.followUpGenerator = followUpGenerator
        self.linkCapture = linkCapture
        self.urlExtractor = urlExtractor
        self.parallelEnabled = parallelEnabled
        self.hybridExecutionEnabled = hybridExecutionEnabled
        self.defaultModel = defaultModel
        self.logger = logger
    }

    func addRoutes(
        to router: RouterGroup<AppRequestContext>,
        streamRouter: RouterGroup<AppRequestContext>? = nil
    ) {
        router.post("", use: create)
        router.get("", use: list)
        router.get("/:id", use: getOne)
        router.delete("/:id", use: delete)
        (streamRouter ?? router).post("/:id/messages/stream", use: streamReply)
        if hybridExecutionEnabled {
            router.post("/:id/messages/prepare", use: prepareLocalReply)
            router.post("/:id/messages/commit", use: commitLocalReply)
            router.delete("/:id/local-executions/:executionID", use: cancelLocalReply)
        }
    }

    // MARK: - CRUD

    @Sendable
    func create(_ req: Request, ctx: AppRequestContext) async throws -> ConversationDTO {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: ConversationCreateRequest.self, context: ctx)
        let tenantID = try user.requireID()
        let pinnedMemoryIDs = Array(body.pinnedMemoryIDs.prefix(5))
        for memoryID in pinnedMemoryIDs {
            guard try await memories.find(tenantID: tenantID, id: memoryID) != nil else {
                throw HTTPError(.badRequest, message: "pinned memory does not belong to the caller")
            }
        }
        if let route = body.routeOverride {
            guard ProviderKind(shared: route.provider) != nil,
                  RouterModelCatalog.entry(provider: route.provider, model: route.model) != nil
            else {
                throw HTTPError(.unprocessableContent, message: "selected model is unavailable")
            }
        }
        let conversation = try Conversation(
            tenantID: tenantID,
            title: (body.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "New conversation",
            spaceID: body.spaceId,
            pinnedMemoryIDs: pinnedMemoryIDs,
            routeOverride: body.routeOverride
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
            messages: messages.map { try $0.toDTO() }
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

    @Sendable
    func prepareLocalReply(_ req: Request, ctx: AppRequestContext) async throws -> ConversationPrepareResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let conversationID = try Self.parseID(ctx)
        let conversation = try await fetch(tenantID: tenantID, id: conversationID)
        let body = try await req.decode(as: ConversationPrepareRequest.self, context: ctx)
        let content = body.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw HTTPError(.badRequest, message: "content required") }
        try await removeExpiredLocalExecutions(tenantID: tenantID)

        let userMessage = ConversationMessage(conversationID: conversationID, role: .user, content: content)
        try await userMessage.save(on: fluent.db())
        let userMessageID = try userMessage.requireID()
        let history = try await ConversationMessage.query(on: fluent.db())
            .filter(\.$conversationID == conversationID)
            .sort(\.$createdAt, .ascending)
            .all()
        let embedding = try await embeddings.embed(content, tenantID: tenantID)
        let semanticHits = try await memories.semanticSearch(tenantID: tenantID, queryEmbedding: embedding, limit: 5)
        let pinnedHits = try await conversation.pinnedMemoryIDs.asyncCompactMap { id in
            try await memories.find(tenantID: tenantID, id: id).map {
                MemorySearchResult(
                    id: $0.savedID,
                    tenantID: tenantID,
                    content: $0.content,
                    createdAt: $0.createdAt,
                    distance: 0,
                    source: MemorySourceKindDTO(rawValue: $0.originKind) ?? .legacy,
                    provider: $0.originProvider,
                    model: $0.originModel
                )
            }
        }
        let pinnedIDs = Set(pinnedHits.map(\.id))
        let hits = pinnedHits + semanticHits.filter { !pinnedIDs.contains($0.id) }.prefix(max(0, 5 - pinnedHits.count))
        let timezone = TimeZone(identifier: user.timezone) ?? .gmt
        let prompt = await Self.buildPrompt(history: history, hits: Array(hits), schedule: scheduleContext(tenantID: tenantID, timezone: timezone))
        let expiresAt = Date().addingTimeInterval(15 * 60)
        let execution = PreparedLocalExecution(
            tenantID: tenantID,
            conversationID: conversationID,
            userMessageID: userMessageID,
            messages: prompt,
            sourceIDs: hits.map(\.id),
            expiresAt: expiresAt
        )
        try await execution.save(on: fluent.db())
        return try ConversationPrepareResponse(
            executionID: execution.requireID(),
            messages: prompt,
            sources: hits.map { QueryHitDTO(id: $0.id, content: $0.content, distance: $0.distance, createdAt: $0.createdAt) },
            expiresAt: expiresAt
        )
    }

    @Sendable
    func commitLocalReply(_ req: Request, ctx: AppRequestContext) async throws -> ConversationCommitResponse {
        let tenantID = try ctx.requireTenantID()
        let conversationID = try Self.parseID(ctx)
        let body = try await req.decode(as: ConversationCommitRequest.self, context: ctx)
        let content = body.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw HTTPError(.badRequest, message: "content required") }
        guard let execution = try await PreparedLocalExecution.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == body.executionID)
            .filter(\.$conversationID == conversationID)
            .first()
        else { throw HTTPError(.notFound, message: "local execution not found") }
        if let messageID = execution.committedMessageID,
           let existing = try await ConversationMessage.find(messageID, on: fluent.db())
        {
            return try ConversationCommitResponse(message: existing.toDTO())
        }
        guard execution.expiresAt > Date() else { throw HTTPError(.gone, message: "local execution expired") }
        let conversation = try await fetch(tenantID: tenantID, id: conversationID)
        let assistant = ConversationMessage(
            conversationID: conversationID,
            role: .assistant,
            content: content,
            sourceMemoryIDs: execution.sourceIDs,
            localExecutionID: body.executionID
        )
        do {
            try await assistant.save(on: fluent.db())
        } catch {
            if let existing = try await ConversationMessage.query(on: fluent.db())
                .filter(\.$localExecutionID == body.executionID)
                .first()
            {
                execution.committedMessageID = try existing.requireID()
                try? await execution.save(on: fluent.db())
                return try ConversationCommitResponse(message: existing.toDTO())
            }
            throw error
        }
        let messageID = try assistant.requireID()
        execution.committedMessageID = messageID
        try await execution.save(on: fluent.db())
        conversation.updatedAt = Date()
        try await conversation.save(on: fluent.db())
        try await MemoryProvenanceRepository(fluent: fluent).enqueueOutput(
            tenantID: tenantID,
            source: .chat,
            sourceID: messageID.uuidString,
            conversationMessageID: messageID,
            content: content,
            provider: "\(body.location.rawValue):\(body.provider)",
            model: body.model
        )
        return try ConversationCommitResponse(message: assistant.toDTO())
    }

    @Sendable
    func cancelLocalReply(_: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try ctx.requireTenantID()
        let conversationID = try Self.parseID(ctx)
        guard let raw = ctx.parameters.get("executionID"), let executionID = UUID(uuidString: raw),
              let execution = try await PreparedLocalExecution.query(on: fluent.db(), tenantID: tenantID)
              .filter(\.$id == executionID)
              .filter(\.$conversationID == conversationID)
              .first()
        else { throw HTTPError(.notFound, message: "local execution not found") }
        guard execution.committedMessageID == nil else {
            throw HTTPError(.conflict, message: "local execution already committed")
        }
        if let userMessageID = execution.userMessageID,
           let userMessage = try await ConversationMessage.find(userMessageID, on: fluent.db())
        {
            try await userMessage.delete(on: fluent.db())
        } else {
            try await execution.delete(on: fluent.db())
        }
        return Response(status: .noContent)
    }

    private func removeExpiredLocalExecutions(tenantID: UUID) async throws {
        let expired = try await PreparedLocalExecution.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$expiresAt < Date())
            .filter(\.$committedMessageID == nil)
            .all()
        for execution in expired {
            if let userMessageID = execution.userMessageID,
               let message = try await ConversationMessage.find(userMessageID, on: fluent.db())
            {
                try await message.delete(on: fluent.db())
            } else {
                try await execution.delete(on: fluent.db())
            }
        }
    }

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
        if body.multiModel?.enabled == true {
            let tier = EntitlementChecker.effectiveTier(tier: user.tierEnum, override: user.tierOverrideEnum)
            guard parallelEnabled, tier == .ultimate else {
                throw HTTPError(.forbidden, message: "router_parallel_requires_ultimate")
            }
        }

        // Request-scoped logger: ctx.logger carries the Hummingbird request
        // id, so every stage below correlates with the access-log line.
        var log = ctx.logger
        log[metadataKey: "tenant_id"] = .string(tenantID.uuidString)
        log[metadataKey: "conversation_id"] = .string(conversationID.uuidString)
        log.info("chat stream begin", metadata: ["content_len": .stringConvertible(content.count)])

        // Persist user turn synchronously so the transcript is durable
        // even if the assistant stream fails downstream.
        let userMessage = try ConversationMessage(
            conversationID: conversation.requireID(),
            role: .user,
            content: content
        )
        try await userMessage.save(on: fluent.db())

        // Load full transcript history so the LLM sees prior turns.
        let history = try await loggedStage("chat.history", logger: log) {
            try await ConversationMessage.query(on: self.fluent.db())
                .filter(\.$conversationID == conversationID)
                .sort(\.$createdAt, .ascending)
                .all()
        }

        // Retrieve grounding memories on the latest user turn.
        let queryEmbedding = try await loggedStage("chat.embed", logger: log) {
            try await embeddings.embed(content, tenantID: tenantID)
        }
        let semanticHits = try await loggedStage("chat.search", logger: log) {
            try await memories.semanticSearch(
                tenantID: tenantID,
                queryEmbedding: queryEmbedding,
                limit: 5
            )
        }
        let pinnedHits = try await conversation.pinnedMemoryIDs.asyncCompactMap { id in
            try await memories.find(tenantID: tenantID, id: id).map {
                MemorySearchResult(
                    id: $0.savedID,
                    tenantID: tenantID,
                    content: $0.content,
                    createdAt: $0.createdAt,
                    distance: 0,
                    source: MemorySourceKindDTO(rawValue: $0.originKind) ?? .legacy,
                    provider: $0.originProvider,
                    model: $0.originModel
                )
            }
        }
        let pinnedIDs = Set(pinnedHits.map(\.id))
        let semanticRemainder = semanticHits
            .filter { !pinnedIDs.contains($0.id) }
            .prefix(5 - min(5, pinnedHits.count))
        let hits = pinnedHits + Array(semanticRemainder)
        log.info("chat grounding", metadata: ["hits": .stringConvertible(hits.count)])

        // HER-340 — inject lightweight schedule awareness (today + next).
        // `nil` (no calendar / no upcoming events) leaves the prompt clean.
        let scheduleTimeZone = TimeZone(identifier: user.timezone) ?? TimeZone.gmt
        let schedule = await scheduleContext(tenantID: tenantID, timezone: scheduleTimeZone)

        let chatRequest = ChatRequest(
            messages: Self.buildPrompt(history: history, hits: hits, schedule: schedule),
            model: defaultModel.isEmpty ? nil : defaultModel,
            temperature: 0.4
        )
        let sessionKey = tenantID.uuidString
        let sessionID = conversationID.uuidString
        // Capture middleware-resolved Hermes routing before the unstructured
        // stream Task starts — @TaskLocal does not propagate across that hop.
        let hermesResolution = ctx.hermesResolution
        let streamService = streamService
        let fluent = fluent
        let logger = log
        let followUpGenerator = followUpGenerator
        let sourceIDs = hits.map(\.id)
        let hitDTOs = hits.map {
            QueryHitDTO(id: $0.id, content: $0.content, distance: $0.distance, createdAt: $0.createdAt)
        }
        // HER-274 — capture inputs needed by the auto-save-link post-
        // processor BEFORE the Task closure copies them. The user's
        // `autoSaveLinks` flag is read on the request (no caching), so
        // a /v1/me/privacy toggle takes effect on the next chat turn.
        let autoSaveEnabled = user.autoSaveLinks
        let linkCapture = linkCapture
        let urlExtractor = urlExtractor
        let userContent = content
        let conversationIDValue = conversationID
        let requestedParallelStrategy = body.multiModel?.enabled == true ? body.multiModel?.strategy : nil
        let parallelExecutionID = ParallelExecutionIDBox()
        let routeOutcome = RouteOutcomeBox()
        let forcedRoute = conversation.routeOverride
        let provenanceRepository = MemoryProvenanceRepository(fluent: fluent)

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
                let cerberusSink: @Sendable (QueryStreamEvent) -> Void = { event in
                    if case let .parallel(progress) = event, progress.kind == .executionStarted {
                        parallelExecutionID.set(progress.executionID)
                    }
                    continuation.yield(event)
                }
                let routeSink: @Sendable (ModelProvenanceDTO) -> Void = { route in
                    routeOutcome.set(route)
                }

                do {
                    let streamStart = DispatchTime.now().uptimeNanoseconds
                    var firstTokenMs: Int64?
                    var tokenCount = 0
                    // Bind routing task-locals and create/consume the upstream
                    // stream in one structured block. Creating the AsyncStream
                    // outside this Task and then pushing a second @TaskLocal
                    // here segfaults on Linux (swift_task_localValuePush).
                    try await LLMRoutingContext.$routeOutcomeSink.withValue(routeSink) {
                        try await LLMRoutingContext.$forcedRoute.withValue(forcedRoute) {
                            try await CerberusStreamContext.$sink.withValue(cerberusSink) {
                                try await LLMRoutingContext.$parallelStrategy.withValue(requestedParallelStrategy) {
                                    try await LLMRoutingContext.$cerberusScope.withValue(
                                        CerberusRequestScope(
                                            surface: .chat,
                                            spaceID: conversation.spaceID,
                                            conversationID: conversationID
                                        )
                                    ) {
                                        try await FailoverNoticeContext.$sink.withValue(fallbackSink) {
                                            try await LLMRoutingContext.$currentUser.withValue(user) {
                                                try await LLMRoutingContext.$currentResolution.withValue(hermesResolution) {
                                                    let chunks = streamService.chatStream(
                                                        sessionKey: sessionKey,
                                                        sessionID: sessionID,
                                                        request: chatRequest
                                                    )
                                                    for try await chunk in chunks {
                                                        if Task.isCancelled {
                                                            break
                                                        }
                                                        if !chunk.delta.isEmpty {
                                                            if firstTokenMs == nil {
                                                                firstTokenMs = Int64((DispatchTime.now().uptimeNanoseconds - streamStart) / 1_000_000)
                                                                logger.info("chat first token", metadata: ["ttft_ms": .stringConvertible(firstTokenMs ?? 0)])
                                                            }
                                                            tokenCount += 1
                                                            assistantBuffer.append(chunk.delta)
                                                            continuation.yield(.token(chunk.delta))
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    logger.info("chat stream complete", metadata: [
                        "tokens": .stringConvertible(tokenCount),
                        "chars": .stringConvertible(assistantBuffer.count),
                        "duration_ms": .stringConvertible(Int64((DispatchTime.now().uptimeNanoseconds - streamStart) / 1_000_000)),
                        "ttft_ms": .stringConvertible(firstTokenMs ?? -1),
                    ])

                    // Hardening: strip tool-error noise / bash leaks from the final
                    // assistant transcript before persist and side effects. This mirrors
                    // the non-stream path in LLMController and prevents raw Hermes
                    // internals (tracebacks, "command not found") from entering durable
                    // convo history or link-capture / follow-up prompts.
                    let cleanedBuffer = HermesToolErrorClassifier.sanitize(content: assistantBuffer) ?? assistantBuffer
                    if cleanedBuffer != assistantBuffer {
                        logger.info("chat stream sanitized tool noise from assistant content")
                    }
                    assistantBuffer = cleanedBuffer

                    if let emptyEvent = ChatStreamCompletionPolicy.emptyCompletionEvent(
                        assistantBuffer: assistantBuffer,
                        tokenCount: tokenCount
                    ) {
                        logger.warning("conversation stream completed without assistant content")
                        continuation.yield(emptyEvent)
                        continuation.finish()
                        return
                    }
                } catch {
                    logger.error("conversation stream upstream failed", metadata: [
                        "error": .string(Logger.redact(String(describing: error))),
                    ])
                    // Surface a provider-specific, actionable message when the
                    // routed transport classified the failure (e.g. credit
                    // exhausted, invalid key, rate limited) instead of a
                    // generic "upstream failure" the user can't act on.
                    let message = (error as? UpstreamErrorResponse)?.userMessage ?? "upstream failure"
                    continuation.yield(.error(message))
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
                        parallelExecutionID: parallelExecutionID.value
                    )
                    try await assistantMessage.save(on: fluent.db())
                    let messageID = try assistantMessage.requireID()
                    let route = routeOutcome.value
                    try await provenanceRepository.enqueueOutput(
                        tenantID: tenantID,
                        source: .chat,
                        sourceID: messageID.uuidString,
                        conversationMessageID: messageID,
                        content: assistantBuffer,
                        provider: route?.provider,
                        model: route?.model
                    )
                    conversation.updatedAt = Date()
                    try await conversation.save(on: fluent.db())
                } catch {
                    logger.error("assistant turn persist failed: \(error)")
                }

                // HER-274 — auto-save-link post-processor. Inspects the
                // user prompt + assistant reply, dedupes URLs across
                // both, and emits one `.linkSaved` event per capture.
                // Skipped when the global flag is off or the user has
                // opted out via /v1/me/privacy. Capture failures are
                // logged-and-skipped: this is a side-effect, not part
                // of the chat contract.
                if let linkCapture, autoSaveEnabled {
                    var seen: Set<String> = []
                    func captureOne(rawURL: String, fromUser: Bool) async {
                        do {
                            let captured = try await linkCapture.captureLink(
                                tenantID: tenantID,
                                url: rawURL,
                                note: "Auto-saved from chat \(conversationIDValue.uuidString)"
                            )
                            continuation.yield(.linkSaved(LinkSavedDTO(
                                url: rawURL,
                                vaultPath: captured.relativePath,
                                capturedAt: Date(),
                                fromUserMessage: fromUser
                            )))
                        } catch {
                            logger.warning("auto-save-link skip url=\(rawURL) error=\(error)")
                        }
                    }
                    for extracted in urlExtractor.extract(from: userContent) {
                        if seen.insert(extracted.normalized).inserted {
                            await captureOne(rawURL: extracted.raw, fromUser: true)
                        }
                    }
                    for extracted in urlExtractor.extract(from: assistantBuffer) {
                        if seen.insert(extracted.normalized).inserted {
                            await captureOne(rawURL: extracted.raw, fromUser: false)
                        }
                    }
                }

                // HER-37 Slice C — best-effort follow-ups, defensive ([]).
                let followUps: [String] = if let followUpGenerator {
                    await followUpGenerator.generate(
                        sessionKey: sessionKey,
                        sessionID: sessionID,
                        summary: assistantBuffer,
                        sources: hitDTOs
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
        schedule: String? = nil
    ) -> [ChatMessage] {
        let context: String = if hits.isEmpty {
            "(no relevant memories were found)"
        } else {
            hits.enumerated().map { offset, hit in
                let provenance = if let provider = hit.provider, let model = hit.model {
                    "prior model output from \(provider)/\(model)"
                } else {
                    hit.source.rawValue
                }
                return "[\(offset + 1)] [\(provenance)] \(hit.content)"
            }.joined(separator: "\n\n")
        }
        // HER-340 — lightweight schedule awareness (today + next event only).
        // Omitted entirely when the calendar isn't connected.
        let scheduleSection = schedule.map { "\n\n\($0)" } ?? ""
        let system = ChatMessage(role: "system", content: """
        You are Lumina, the user's second-brain assistant. Use the
        retrieved memories below to ground your answer. Cite by their
        bracket number when relevant (e.g. "[1]"). Keep the reply concise
        and conversational. If the memories do not cover the question,
        say so plainly rather than inventing detail.

        Retrieved memories:
        \(context)\(scheduleSection)

        Prior model outputs are drafts, not authoritative user facts. Prefer
        direct user memories when sources disagree and state uncertainty.
        """)
        let turns = history.map { ChatMessage(role: $0.role, content: $0.content) }
        return [system] + turns
    }

    /// HER-340 — compact schedule block for prompt injection: whether the
    /// user is busy right now, today's remaining events, and the next one.
    /// Returns `nil` when no calendar is connected or no upcoming events
    /// exist, so the prompt stays clean for non-calendar users. Times are
    /// rendered in `timezone` (the user's tz, falling back to UTC).
    func scheduleContext(tenantID: UUID, timezone: TimeZone, now: Date = Date()) async -> String? {
        let rows = try? await CalendarEvent.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$status != "cancelled")
            .filter(\.$endsAt >= now)
            .sort(\.$startsAt, .ascending)
            .limit(12)
            .all()
        guard let rows, !rows.isEmpty else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let fmt = DateFormatter()
        fmt.timeZone = timezone
        fmt.dateFormat = "HH:mm"

        let ongoing = rows.first { $0.startsAt <= now && now < $0.endsAt }
        let today = rows.filter { cal.isDate($0.startsAt, inSameDayAs: now) && $0.startsAt >= now }
        let next = rows.first { $0.startsAt > now }

        var lines = ["The user's calendar (times in their local timezone):"]
        if let ongoing {
            lines.append("- Now: in \"\(ongoing.title)\" until \(fmt.string(from: ongoing.endsAt))")
        } else {
            lines.append("- Now: no event in progress")
        }
        if today.isEmpty {
            lines.append("- Today: nothing else scheduled")
        } else {
            let preview = today.prefix(4).map { "\($0.title) \(fmt.string(from: $0.startsAt))" }.joined(separator: ", ")
            lines.append("- Today: \(today.count) more — \(preview)")
        }
        if let next, !cal.isDate(next.startsAt, inSameDayAs: now) {
            let dayFmt = DateFormatter()
            dayFmt.timeZone = timezone
            dayFmt.dateFormat = "EEE d MMM, HH:mm"
            lines.append("- Next: \"\(next.title)\" \(dayFmt.string(from: next.startsAt))")
        }
        return lines.joined(separator: "\n")
    }
}

private final class ParallelExecutionIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UUID?

    var value: UUID? {
        lock.withLock { storage }
    }

    func set(_ value: UUID) {
        lock.withLock { storage = value }
    }
}

private final class RouteOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: ModelProvenanceDTO?

    var value: ModelProvenanceDTO? {
        lock.withLock { storage }
    }

    func set(_ value: ModelProvenanceDTO) {
        lock.withLock { storage = value }
    }
}

private extension Array {
    func asyncCompactMap<T>(_ transform: (Element) async throws -> T?) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self {
            if let value = try await transform(element) {
                result.append(value)
            }
        }
        return result
    }
}
