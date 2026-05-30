import FluentKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdFluent
import Logging

struct CaptureSafariRequest: Codable {
    let url: String
    /// HER-90 — the client encodes this as `notes` (snake_case passthrough).
    /// The previous server field was `note`, so the annotation the user typed
    /// in the share sheet was silently dropped on decode. Named `notes` to
    /// match the wire shape `CaptureSafariEndpoints` sends.
    let notes: String?
    /// HER-105 — optional Space to file the captured link into. nil = unfiled.
    let spaceId: UUID?

    /// Explicit keys: `AppRequestContext` uses Hummingbird's default request
    /// decoder (no `convertFromSnakeCase`), so the client's `space_id` must be
    /// mapped here or it decodes as nil and the link lands unfiled.
    enum CodingKeys: String, CodingKey {
        case url
        case notes
        case spaceId = "space_id"
    }
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
            result = try await service.captureLink(
                tenantID: tenantID,
                url: body.url,
                note: body.notes,
                spaceID: body.spaceId,
            )
        } catch LinkCaptureService.CaptureError.invalidURL {
            throw HTTPError(.badRequest, message: "Invalid URL")
        } catch LinkCaptureService.CaptureError.nonPublicHost {
            throw HTTPError(.badRequest, message: "URL host is not enrichable")
        } catch LinkCaptureService.CaptureError.unknownSpace {
            throw HTTPError(.badRequest, message: "`space_id` does not belong to the caller")
        }

        let responseBody = CaptureSafariResponse(id: result.fileID, path: result.relativePath, status: "accepted")
        var res = try await responseBody.response(from: request, context: ctx)
        res.status = .accepted
        return res
    }
}
