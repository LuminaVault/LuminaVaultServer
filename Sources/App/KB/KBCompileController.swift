import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

struct KBCompileRequest: Codable {
    let files: [InternalKBCompileFile]
    let hint: String?
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
        let mappedFiles = result.writtenFiles.map {
            LuminaVaultShared.KBCompileWrittenFile(path: $0.path, size: $0.size)
        }
        let mappedMemories = result.memories.map {
            LuminaVaultShared.KBCompileMemoryRef(id: $0.id, content: $0.content)
        }
        return KBCompileResponse(
            writtenFiles: mappedFiles,
            memories: mappedMemories,
            summary: result.summary,
        )
    }
}

extension KBCompileResponse: ResponseEncodable {}
