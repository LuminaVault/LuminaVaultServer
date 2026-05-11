import Foundation
import Hummingbird
import Logging

struct KBCompileRequest: Codable {
    let files: [KBCompileFile]
    let hint: String?
}

struct KBCompileResponse: Codable, ResponseEncodable {
    let writtenFiles: [KBCompileWrittenFile]
    let memories: [KBCompileMemoryRef]
    let summary: String
}

struct KBCompileController {
    let service: KBCompileService
    let achievements: AchievementsService?

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: compile)
    }

    @Sendable
    func compile(_ req: Request, ctx: AppRequestContext) async throws -> KBCompileResponse {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: KBCompileRequest.self, context: ctx)
        guard !body.files.isEmpty else {
            throw HTTPError(.badRequest, message: "files array required")
        }
        let tenantID = try user.requireID()
        let result = try await service.compile(
            tenantID: tenantID,
            profileUsername: user.username,
            files: body.files,
            hint: body.hint,
        )
        if let achievements {
            Task.detached { await achievements.recordAndPush(tenantID: tenantID, event: .kbCompiled) }
        }
        return KBCompileResponse(
            writtenFiles: result.writtenFiles,
            memories: result.memories,
            summary: result.summary,
        )
    }
}
