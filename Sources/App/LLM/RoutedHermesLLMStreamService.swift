import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging
import LuminaVaultShared
import Metrics
import NIOCore

/// Routes the user-facing chat **stream** through a tenant's own provider
/// when they are in BYOK mode, instead of always hitting the central Hermes
/// gateway. HER-37 left streaming on the gateway only ("routed/Gemini
/// streaming is out of scope"); this fills that gap so the iOS BYOK toggle
/// actually changes the streaming chat, not just the non-streaming
/// `/v1/query` + follow-up paths.
///
/// Resolution per request (keyed by `sessionKey` = tenant UUID):
///   1. No tenant / no pref / `managed` mode → delegate to `fallback`
///      (the Hermes gateway, unchanged managed behaviour).
///   2. `byok` + a provider we can stream natively + a stored credential →
///      stream directly from that provider.
///   3. `byok` but provider has no native streaming impl yet → delegate to
///      `fallback` so the turn still completes (degrades, never blanks).
///
/// Phase 1 streams **Gemini** natively (`streamGenerateContent?alt=sse`).
/// Other BYOK providers fall through to the gateway until their streaming
/// adapters land. BYOK is already non-agentic in this codebase (the
/// non-streaming `RoutedLLMTransport` calls providers directly, bypassing
/// Hermes tools/memory), so this path is consistent — no skills/tools.
struct RoutedHermesLLMStreamService: HermesLLMStreamService {
    /// Managed-mode upstream (central Hermes gateway).
    let fallback: any HermesLLMStreamService
    let preferences: UserLLMPreferenceRepository
    let credentials: UserCredentialStore
    let httpClient: HTTPClient
    let logger: Logger
    let requestTimeout: TimeAmount
    let streamIdleTimeout: TimeAmount

    private let byokCounter = Counter(label: "luminavault.llm.chat.stream.byok")
    private let byokFailureCounter = Counter(label: "luminavault.llm.chat.stream.byok.failure")

    init(
        fallback: any HermesLLMStreamService,
        preferences: UserLLMPreferenceRepository,
        credentials: UserCredentialStore,
        httpClient: HTTPClient,
        logger: Logger,
        requestTimeout: TimeAmount = .seconds(120),
        streamIdleTimeout: TimeAmount = .seconds(60),
    ) {
        self.fallback = fallback
        self.preferences = preferences
        self.credentials = credentials
        self.httpClient = httpClient
        self.logger = logger
        self.requestTimeout = requestTimeout
        self.streamIdleTimeout = streamIdleTimeout
    }

    /// A resolved native-streaming plan for a BYOK tenant.
    private struct GeminiPlan {
        let apiKey: String
        let model: String
        let payload: Data
    }

    func chatStream(
        sessionKey: String,
        sessionID: String?,
        request: ChatRequest,
    ) -> AsyncThrowingStream<ChatStreamChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<ChatStreamChunk, Error>.makeStream()
        let work = Task {
            do {
                if let plan = try await resolveGeminiPlan(sessionKey: sessionKey, request: request) {
                    byokCounter.increment()
                    logger.info("chat stream routed to BYOK gemini", metadata: [
                        "model": .string(plan.model),
                    ])
                    try await streamGemini(plan: plan, continuation: continuation)
                    continuation.finish()
                } else {
                    for try await chunk in fallback.chatStream(
                        sessionKey: sessionKey,
                        sessionID: sessionID,
                        request: request,
                    ) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                }
            } catch {
                byokFailureCounter.increment()
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    // MARK: - Resolution

    /// Returns a Gemini streaming plan iff the tenant is BYOK, has selected
    /// Gemini as primary, and has a stored Gemini key. Any miss returns nil
    /// (→ caller delegates to the managed gateway).
    private func resolveGeminiPlan(
        sessionKey: String,
        request: ChatRequest,
    ) async throws -> GeminiPlan? {
        guard let tenantID = UUID(uuidString: sessionKey) else { return nil }
        guard
            let pref = try? await preferences.get(tenantID: tenantID),
            pref.mode == .byok,
            pref.primaryProvider == .gemini
        else { return nil }
        guard
            let credential = try? await credentials.credential(for: .gemini, tenantID: tenantID),
            let apiKey = credential.apiKey,
            !apiKey.isEmpty
        else {
            logger.warning("byok gemini selected but no stored key; delegating to gateway", metadata: [
                "tenant_id": .string(tenantID.uuidString),
            ])
            return nil
        }
        let model = pref.primaryModel.isEmpty ? "gemini-2.5-flash" : pref.primaryModel
        let payload = try Self.makeOpenAIPayload(model: model, request: request)
        return GeminiPlan(apiKey: apiKey, model: model, payload: payload)
    }

    /// Encode an OpenAI-style chat payload from a `ChatRequest`. Reused by
    /// `GeminiContentsAdapter.makeStreamRequest` to build the Gemini body,
    /// keeping the translation pipeline identical to the non-streaming path.
    static func makeOpenAIPayload(model: String, request: ChatRequest) throws -> Data {
        struct Payload: Encodable {
            let model: String
            let messages: [ChatMessage]
            let temperature: Double?
        }
        return try JSONEncoder().encode(
            Payload(model: model, messages: request.messages, temperature: request.temperature),
        )
    }

    // MARK: - Gemini SSE

    private func streamGemini(
        plan: GeminiPlan,
        continuation: AsyncThrowingStream<ChatStreamChunk, Error>.Continuation,
    ) async throws {
        let (url, body) = try GeminiContentsAdapter.makeStreamRequest(payload: plan.payload, apiKey: plan.apiKey)

        var httpReq = HTTPClientRequest(url: url.absoluteString)
        httpReq.method = .POST
        httpReq.headers.add(name: "Content-Type", value: "application/json")
        httpReq.headers.add(name: "Accept", value: "text/event-stream")
        httpReq.body = .bytes(body)

        let response = try await httpClient.execute(httpReq, timeout: requestTimeout)
        guard (200 ..< 300).contains(Int(response.status.code)) else {
            // Drain a bounded slice of the error body for the log.
            var detail = ""
            if var bodyBuf = try? await response.body.collect(upTo: 4096) {
                detail = bodyBuf.readString(length: bodyBuf.readableBytes) ?? ""
            }
            logger.error("gemini stream upstream non-2xx", metadata: [
                "status": .stringConvertible(response.status.code),
                "detail": .string(Logger.redact(detail)),
            ])
            throw HTTPError(.badGateway, message: "gemini stream upstream error (\(response.status.code))")
        }

        var buffer = ""
        for try await chunk in response.body {
            if Task.isCancelled { break }
            if let text = chunk.getString(at: chunk.readerIndex, length: chunk.readableBytes) {
                buffer.append(text)
            }
            while let terminator = buffer.range(of: "\n\n") {
                let record = String(buffer[..<terminator.lowerBound])
                buffer.removeSubrange(..<terminator.upperBound)
                if processGeminiRecord(record, yield: { continuation.yield($0) }) { return }
            }
        }
        if !buffer.isEmpty {
            _ = processGeminiRecord(buffer, yield: { continuation.yield($0) })
        }
    }

    /// Parse one SSE record (one or more lines). Returns `true` when the
    /// terminal chunk (non-nil `finishReason`) was seen.
    private func processGeminiRecord(
        _ record: String,
        yield: (ChatStreamChunk) -> Void,
    ) -> Bool {
        for rawLine in record.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard
                let data = payload.data(using: .utf8),
                let parsed = GeminiContentsAdapter.parseStreamObject(data)
            else { continue }
            if !parsed.delta.isEmpty || parsed.finishReason != nil {
                yield(ChatStreamChunk(delta: parsed.delta, finishReason: parsed.finishReason))
            }
            if parsed.finishReason != nil { return true }
        }
        return false
    }
}
