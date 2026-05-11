import Foundation
import Hummingbird

struct MemoRequest: Codable {
    let topic: String
    let hint: String?
    let save: Bool?
}

struct MemoResponse: Codable, ResponseEncodable {
    let memo: String
    let path: String?
    let sourceMemoryIds: [UUID]
    let summary: String
}

struct MemoController {
    let service: MemoGeneratorService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: generate)
    }

    @Sendable
    func generate(_ req: Request, ctx: AppRequestContext) async throws -> MemoResponse {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: MemoRequest.self, context: ctx)
        let result = try await service.generate(
            tenantID: user.requireID(),
            profileUsername: user.username,
            topic: body.topic,
            hint: body.hint,
            save: body.save ?? true,
        )
        return MemoResponse(
            memo: result.memo,
            path: result.path,
            sourceMemoryIds: result.sourceMemoryIDs,
            summary: result.summary,
        )
    }
}
