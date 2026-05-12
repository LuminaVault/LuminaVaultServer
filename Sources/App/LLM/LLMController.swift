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
            Task.detached {
                try? await pushService.notifyLLMReply(
                    userID: userID,
                    username: username,
                    response: response,
                )
            }
            if let achievements {
                Task.detached { await achievements.recordAndPush(tenantID: userID, event: .chatCompleted) }
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
