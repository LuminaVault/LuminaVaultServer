import Foundation
import Hummingbird
import Logging

struct KBCompileRequest: Codable, Sendable {
    let files: [KBCompileFile]
    let hint: String?
}

struct KBCompileResponse: Codable, ResponseEncodable, Sendable {
    let writtenFiles: [KBCompileWrittenFile]
    let memories: [KBCompileMemoryRef]
    let summary: String
}

struct KBCompileController {
    let service: KBCompileService

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
        let result = try await service.compile(
            tenantID: try user.requireID(),
            profileUsername: user.username,
            files: body.files,
            hint: body.hint
        )
        return KBCompileResponse(
            writtenFiles: result.writtenFiles,
            memories: result.memories,
            summary: result.summary
        )
    }
}
