import Foundation
import HTTPTypes
import Hummingbird
import Logging
import LuminaVaultShared

/// HER-205 — `POST /v1/vision/embed`. Accepts a raw image body with
/// `Content-Type: image/{png,jpeg,webp,heic}`, returns a 1536-dim
/// embedding. Optional `?indexAs=memory&memoryId=<uuid>` ALSO writes the
/// embedding to `memories.embedding` for ANN search.
///
/// Auth + entitlement (`.memoryQuery`) + rate-limit are applied by the
/// route group in `App+build.swift`.
struct VisionEmbedController {
    let service: VisionEmbedService
    let logger: Logger
    /// Hard cap on the image body. Anything larger short-circuits with
    /// `413 Payload Too Large` before we touch the upstream provider.
    static let maxBodyBytes: Int = 8 * 1024 * 1024

    static let acceptedMimes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/webp",
        "image/heic",
    ]

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/embed", use: embed)
    }

    @Sendable
    func embed(_ request: Request, ctx: AppRequestContext) async throws -> VisionEmbedResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()

        let mime = (request.headers[.contentType] ?? "")
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            ?? ""
        guard Self.acceptedMimes.contains(mime) else {
            throw HTTPError(.unsupportedMediaType, message: "Content-Type must be one of: \(Self.acceptedMimes.sorted().joined(separator: ", "))")
        }

        if let lengthHeader = request.headers[.contentLength],
           let declared = Int(lengthHeader),
           declared > Self.maxBodyBytes {
            throw HTTPError(.contentTooLarge, message: "image body exceeds \(Self.maxBodyBytes) byte cap")
        }

        let buffer: ByteBuffer
        do {
            buffer = try await request.body.collect(upTo: Self.maxBodyBytes)
        } catch {
            logger.warning("vision embed body collect failed: \(error)")
            throw HTTPError(.contentTooLarge, message: "image body exceeds \(Self.maxBodyBytes) byte cap")
        }

        let indexAsMemory = try Self.parseIndexAsMemory(from: request)

        // TODO(HER-205-followup): server-side resize to 768 px long edge
        // to cut provider cost. Cross-platform image resize on Linux
        // Swift needs ImageMagick/libvips; deferring until we land
        // image-toolkit decision in HER-205 sub-ticket.

        return try await service.embed(
            image: buffer,
            mime: mime,
            tenantID: tenantID,
            indexAsMemory: indexAsMemory,
        )
    }

    /// Parses `?indexAs=memory&memoryId=<uuid>`. Returns the UUID when
    /// both query params are present and well-formed; returns nil when
    /// neither is supplied. Throws 400 when one is present but the pair
    /// is malformed — defaults are forbidden because the SQL UPDATE
    /// targets a specific row.
    static func parseIndexAsMemory(from request: Request) throws -> UUID? {
        let indexAs = request.uri.queryParameters["indexAs"].map(String.init)
        let memoryIDRaw = request.uri.queryParameters["memoryId"].map(String.init)
        if indexAs == nil, memoryIDRaw == nil { return nil }
        guard indexAs == "memory" else {
            throw HTTPError(.badRequest, message: "indexAs must be 'memory' when supplied")
        }
        guard let memoryIDRaw, let memoryID = UUID(uuidString: memoryIDRaw) else {
            throw HTTPError(.badRequest, message: "memoryId required and must be a UUID when indexAs=memory")
        }
        return memoryID
    }
}
