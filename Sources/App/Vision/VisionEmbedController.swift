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
    /// Only needed by `/search`, which runs the image's vector against
    /// `memories.embedding` — the same column `/embed?indexAs=memory` writes.
    let memories: MemoryRepository
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
        router.post("/search", use: search)
    }

    /// Default and ceiling for `?limit=`. The ceiling exists because each hit
    /// carries full memory content, and an unbounded limit on a vector scan is
    /// an easy way to return several megabytes by accident.
    static let defaultSearchLimit = 10
    static let maxSearchLimit = 50

    /// `POST /v1/vision/search` — find the memories nearest an image.
    ///
    /// iOS does this by running on-device OCR and searching with the extracted
    /// text. A browser has no equivalent, and the obvious server-side answer —
    /// OCR the image, then search — would mean adding a vision-LLM round trip
    /// and a provider to configure.
    ///
    /// It is not needed. `/embed` already returns a vector documented as
    /// "compatible with `memories.embedding`", and `indexAs=memory` writes into
    /// that very column, so image and memory vectors share a space by
    /// construction. Searching is therefore embed-then-ANN: no OCR, no second
    /// provider, no text in the middle to mistranslate the picture.
    ///
    /// Uses the document arm (`semanticSearch`) rather than the hybrid one,
    /// because the hybrid path's lexical half needs query text that an image
    /// does not have.
    @Sendable
    func search(_ request: Request, ctx: AppRequestContext) async throws -> VisionSearchResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()

        let mime = Self.contentType(of: request)
        guard Self.acceptedMimes.contains(mime) else {
            throw HTTPError(.unsupportedMediaType, message: "Content-Type must be one of: \(Self.acceptedMimes.sorted().joined(separator: ", "))")
        }

        if let lengthHeader = request.headers[.contentLength],
           let declared = Int(lengthHeader),
           declared > Self.maxBodyBytes
        {
            throw HTTPError(.contentTooLarge, message: "image body exceeds \(Self.maxBodyBytes) byte cap")
        }

        let limit = try Self.parseSearchLimit(from: request)

        let buffer: ByteBuffer
        do {
            buffer = try await request.body.collect(upTo: Self.maxBodyBytes)
        } catch {
            logger.warning("vision search body collect failed: \(error)")
            throw HTTPError(.contentTooLarge, message: "image body exceeds \(Self.maxBodyBytes) byte cap")
        }

        // `indexAsMemory: nil` — searching must never write. The same service
        // call with a memory id is what `/embed` uses to index.
        let embedded = try await service.embed(
            image: buffer,
            mime: mime,
            tenantID: tenantID,
            indexAsMemory: nil
        )

        let results = try await memories.semanticSearch(
            queryEmbedding: embedded.embedding,
            limit: limit,
            context: ctx
        )

        return VisionSearchResponse(
            hits: results.map {
                VisionSearchHit(id: $0.id, content: $0.content, distance: $0.distance, createdAt: $0.createdAt)
            },
            model: embedded.model
        )
    }

    /// The bare media type, without any `; charset=` or other parameters.
    static func contentType(of request: Request) -> String {
        (request.headers[.contentType] ?? "")
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            ?? ""
    }

    /// Parses `?limit=`, rejecting nonsense rather than silently clamping it:
    /// a caller asking for 500 results has misunderstood something, and
    /// quietly returning 50 hides that.
    static func parseSearchLimit(from request: Request) throws -> Int {
        guard let raw = request.uri.queryParameters["limit"].map(String.init) else {
            return defaultSearchLimit
        }
        guard let value = Int(raw), value > 0, value <= maxSearchLimit else {
            throw HTTPError(.badRequest, message: "limit must be an integer between 1 and \(maxSearchLimit)")
        }
        return value
    }

    @Sendable
    func embed(_ request: Request, ctx: AppRequestContext) async throws -> VisionEmbedResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()

        let mime = Self.contentType(of: request)
        guard Self.acceptedMimes.contains(mime) else {
            throw HTTPError(.unsupportedMediaType, message: "Content-Type must be one of: \(Self.acceptedMimes.sorted().joined(separator: ", "))")
        }

        if let lengthHeader = request.headers[.contentLength],
           let declared = Int(lengthHeader),
           declared > Self.maxBodyBytes
        {
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
            indexAsMemory: indexAsMemory
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
        if indexAs == nil, memoryIDRaw == nil {
            return nil
        }
        guard indexAs == "memory" else {
            throw HTTPError(.badRequest, message: "indexAs must be 'memory' when supplied")
        }
        guard let memoryIDRaw, let memoryID = UUID(uuidString: memoryIDRaw) else {
            throw HTTPError(.badRequest, message: "memoryId required and must be a UUID when indexAs=memory")
        }
        return memoryID
    }
}
