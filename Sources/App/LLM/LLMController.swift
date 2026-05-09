import Hummingbird
import Logging

struct LLMController {
    let service: any HermesLLMService
    let telemetry: RouteTelemetry
    let notificationService: APNSNotificationService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/chat", use: chat)
    }

    @Sendable
    func chat(_ req: Request, ctx: AppRequestContext) async throws -> ChatResponse {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: ChatRequest.self, context: ctx)
        guard !body.messages.isEmpty else {
            throw HTTPError(.badRequest, message: "messages required")
        }
        return try await telemetry.observe("llm.chat") {
            let response = try await service.chat(profileUsername: user.username, request: body)
            try await notificationService.notifyLLMReply(username: user.username, response: response)
            return response
        }
    }
}
