import FluentKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdFluent
import Logging

struct CaptureSafariRequest: Codable {
    let url: String
    let note: String?
}

struct CaptureSafariResponse: Codable, ResponseEncodable {
    let id: UUID
    let path: String
    let status: String
}

/// HER-90 / HER-274 — thin HTTP shim over `LinkCaptureService`. The
/// share-extension flow and the chat auto-save-link post-processor
/// land on the same persistence pipeline so the vault never sees two
/// shapes of capture rows.
struct CaptureController {
    let service: LinkCaptureService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/safari", use: captureSafari)
    }

    @Sendable
    func captureSafari(_ request: Request, ctx: AppRequestContext) async throws -> Response {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let body = try await request.decode(as: CaptureSafariRequest.self, context: ctx)

        let result: LinkCaptureService.CapturedLink
        do {
            result = try await service.captureLink(tenantID: tenantID, url: body.url, note: body.note)
        } catch LinkCaptureService.CaptureError.invalidURL {
            throw HTTPError(.badRequest, message: "Invalid URL")
        } catch LinkCaptureService.CaptureError.nonPublicHost {
            throw HTTPError(.badRequest, message: "URL host is not enrichable")
        }

        let responseBody = CaptureSafariResponse(id: result.fileID, path: result.relativePath, status: "accepted")
        var res = try await responseBody.response(from: request, context: ctx)
        res.status = .accepted
        return res
    }
}
