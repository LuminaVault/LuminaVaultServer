import Foundation
import HTTPTypes
import Hummingbird
import Logging
import LuminaVaultShared

struct LLMController {
    let service: any HermesLLMService
    let telemetry: RouteTelemetry
    let notificationService: APNSNotificationService
    let achievements: AchievementsService?
    let usageMeter: UsageMeterService?

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
            let response = try await service.chat(profileUsername: user.username, request: finalBody)
            // Push delivery is best-effort: never block the chat response.
            // Capture only what the detached task needs to be Sendable.
            let userID = try user.requireID()
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
                Task { await achievements.recordAndPush(tenantID: userID, event: .chatCompleted) }
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
