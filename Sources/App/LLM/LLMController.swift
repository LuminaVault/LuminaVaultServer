import Foundation
import HTTPTypes
import Hummingbird
import Logging
import LuminaVaultShared

struct LLMController {
    let service: any HermesLLMService
    let telemetry: RouteTelemetry
    let notificationService: APNSNotificationService
    let achievements: AchievementsWorker?
    let usageMeter: UsageMeterService?
    /// HER-240 / spec ticket #4 — optional pre-enricher that rewrites
    /// user-role messages with `<context>` blocks for any URLs found.
    /// Nil disables silently; per-request `X-Skip-URL-Enrichment: true`
    /// header also disables.
    let urlPreEnricher: ChatURLPreEnricher?

    init(
        service: any HermesLLMService,
        telemetry: RouteTelemetry,
        notificationService: APNSNotificationService,
        achievements: AchievementsWorker? = nil,
        usageMeter: UsageMeterService? = nil,
        urlPreEnricher: ChatURLPreEnricher? = nil,
    ) {
        self.service = service
        self.telemetry = telemetry
        self.notificationService = notificationService
        self.achievements = achievements
        self.usageMeter = usageMeter
        self.urlPreEnricher = urlPreEnricher
    }

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/chat", use: chat)
    }

    /// HER-200 H2 — schedules the APNS push side-effect for a completed
    /// chat as a structured `Task`. Errors are routed to the supplied
    /// logger; cancellation is silent. Returns the task handle so callers
    /// (and tests) can await completion if they need to assert behavior.
    @discardableResult
    static func dispatchChatPushSideEffect(
        pushService: APNSNotificationService,
        userID: UUID,
        username: String,
        response: ChatResponse,
        logger: Logger = Logger(label: "lv.llm"),
    ) -> Task<Void, Never> {
        Task {
            do {
                try await pushService.notifyLLMReply(
                    userID: userID,
                    username: username,
                    response: response,
                )
            } catch is CancellationError {
                // Client disconnected before push completed; ignore.
            } catch {
                logger.warning("push notify failed: \(error)")
            }
        }
    }

    @Sendable
    func chat(_ req: Request, ctx: AppRequestContext) async throws -> EditedResponse<ChatResponse> {
        let user = try ctx.requireIdentity()
        var body = try await req.decode(as: ChatRequest.self, context: ctx)
        guard !body.messages.isEmpty else {
            throw HTTPError(.badRequest, message: "messages required")
        }

        // HER-240 / spec ticket #4 — pre-enrich user messages with
        // <context> blocks for any URLs unless caller opted out via
        // X-Skip-URL-Enrichment: true.
        let skipEnrichment = req.headers[HTTPField.Name("X-Skip-URL-Enrichment")!]?.lowercased() == "true"
        if !skipEnrichment, let preEnricher = urlPreEnricher {
            let enriched = await preEnricher.enrich(messages: body.messages)
            body = ChatRequest(
                messages: enriched,
                model: body.model,
                temperature: body.temperature,
                stream: body.stream,
                tools: body.tools,
                tool_choice: body.tool_choice,
            )
        }

        var isDegraded = false
        if let usageMeter {
            let tier = UserTier(rawValue: user.tier) ?? .trial
            let decision = try await usageMeter.checkBudget(tenantID: user.requireID(), tier: tier)
            switch decision {
            case .allow:
                break
            case let .degrade(model):
                body = ChatRequest(
                    messages: body.messages,
                    model: model,
                    temperature: body.temperature,
                    stream: body.stream,
                    tools: body.tools,
                    tool_choice: body.tool_choice,
                )
                isDegraded = true
            case let .deny(retryAfter):
                throw UsageCapExceededError(retryAfter: retryAfter)
            }
        }

        let finalBody = body
        let finalIsDegraded = isDegraded

        return try await telemetry.observe("llm.chat") {
            let userID = try user.requireID()
            let response = try await service.chat(
                sessionKey: userID.uuidString,
                sessionID: finalBody.sessionID,
                request: finalBody,
            )
            // Push delivery is best-effort: never block the chat response.
            // Capture only what the detached task needs to be Sendable.
            let username = user.username
            let pushService = notificationService
            // HER-200 H2 — structured `Task` so the side-effects inherit
            // task locals + priority and errors are logged explicitly
            // rather than swallowed by `try?`. Implementation lives in a
            // package-scoped helper for unit tests.
            _ = Self.dispatchChatPushSideEffect(
                pushService: pushService,
                userID: userID,
                username: username,
                response: response,
            )
            if let achievements {
                achievements.enqueue(tenantID: userID, event: .chatCompleted)
            }
            if finalIsDegraded {
                var headers = HTTPFields()
                if let headerName = HTTPField.Name("X-LuminaVault-Degraded") {
                    headers[headerName] = "true"
                }
                return EditedResponse(headers: headers, response: response)
            }
            return EditedResponse(response: response)
        }
    }
}
