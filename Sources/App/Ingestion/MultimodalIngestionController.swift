import Foundation
import HTTPTypes
import Hummingbird
import LuminaVaultShared

extension IngestionBatchDTO: @retroactive ResponseEncodable {}
extension IngestionBatchListDTO: @retroactive ResponseEncodable {}

struct MultimodalIngestionController {
    let service: MultimodalIngestionService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: create)
        router.get("", use: list)
        router.get("/:batchID", use: detail)
        router.get("/:batchID/events", use: events)
        router.put("/:batchID/items/:itemID/chunks/:index", use: uploadChunk)
        router.post("/:batchID/items/:itemID/complete", use: complete)
        router.post("/:batchID/items/:itemID/retry", use: retry)
        router.delete("/:batchID/items/:itemID", use: cancel)
    }

    @Sendable private func events(_ request: Request, ctx: AppRequestContext) async throws -> IngestionSSEResponse {
        let batchID: UUID = try parameter("batchID", ctx: ctx)
        let tenantID = try ctx.requireTenantID()
        _ = try await service.detail(tenantID: tenantID, batchID: batchID)
        let query = request.uri.queryParameters
        let headerCursor = request.headers[HTTPField.Name("Last-Event-ID")!].flatMap { Int64($0) }
        let cursor = query["after"].flatMap { Int64(String($0)) } ?? headerCursor ?? 0
        return IngestionSSEResponse(service: service, tenantID: tenantID, batchID: batchID, after: cursor)
    }

    func addPublicSourceRoute(to router: Router<AppRequestContext>) {
        router.get("/v1/ingestion-sources/:token", use: source)
        router.head("/v1/ingestion-sources/:token", use: source)
    }

    @Sendable private func source(_ request: Request, ctx: AppRequestContext) async throws -> Response {
        guard let token = ctx.parameters.get("token") else { throw HTTPError(.notFound) }
        let source = try await service.source(token: token)
        var headers = HTTPFields()
        headers[.contentType] = source.contentType
        headers[.cacheControl] = "private, no-store"
        headers[.acceptRanges] = "bytes"
        if let etag = source.etag {
            headers[.eTag] = "\"\(etag)\""
        }
        headers[.contentDisposition] = "attachment; filename=\"\(source.fileName.replacingOccurrences(of: "\"", with: ""))\""
        if request.method == .head {
            headers[.contentLength] = String(source.size)
            return Response(status: .ok, headers: headers)
        }
        if let rawRange = request.headers[.range] {
            let range = try Self.parseRange(rawRange, size: source.size)
            headers[.contentLength] = String(range.count)
            headers[.contentRange] = "bytes \(range.lowerBound)-\(range.upperBound)/\(source.size)"
            let body = try await FileIO().loadFile(path: source.path, range: range, context: ctx)
            return Response(status: .partialContent, headers: headers, body: body)
        }
        headers[.contentLength] = String(source.size)
        let body = try await FileIO().loadFile(path: source.path, context: ctx)
        return Response(status: .ok, headers: headers, body: body)
    }

    static func parseRange(_ value: String, size: Int64) throws -> ClosedRange<Int> {
        guard size > 0, value.hasPrefix("bytes="), !value.contains(",") else {
            throw HTTPError(.rangeNotSatisfiable)
        }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw HTTPError(.rangeNotSatisfiable) }
        let start: Int64
        let end: Int64
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { throw HTTPError(.rangeNotSatisfiable) }
            start = max(0, size - suffix)
            end = size - 1
        } else {
            guard let parsedStart = Int64(parts[0]), parsedStart >= 0, parsedStart < size else {
                throw HTTPError(.rangeNotSatisfiable)
            }
            start = parsedStart
            end = min(parts[1].isEmpty ? size - 1 : (Int64(parts[1]) ?? -1), size - 1)
            guard end >= start else { throw HTTPError(.rangeNotSatisfiable) }
        }
        guard start <= Int.max, end <= Int.max else { throw HTTPError(.rangeNotSatisfiable) }
        return Int(start) ... Int(end)
    }

    @Sendable private func create(_ request: Request, ctx: AppRequestContext) async throws -> IngestionBatchDTO {
        let tenantID = try ctx.requireTenantID()
        let body = try await request.decode(as: IngestionCreateRequest.self, context: ctx)
        return try await service.create(tenantID: tenantID, request: body)
    }

    @Sendable private func list(_: Request, ctx: AppRequestContext) async throws -> IngestionBatchListDTO {
        try await service.list(tenantID: ctx.requireTenantID())
    }

    @Sendable private func detail(_: Request, ctx: AppRequestContext) async throws -> IngestionBatchDTO {
        try await service.detail(tenantID: ctx.requireTenantID(), batchID: parameter("batchID", ctx: ctx))
    }

    @Sendable private func uploadChunk(_ request: Request, ctx: AppRequestContext) async throws -> HTTPResponse.Status {
        let tenantID = try ctx.requireTenantID()
        let batchID = try parameter("batchID", ctx: ctx)
        let itemID = try parameter("itemID", ctx: ctx)
        guard let rawIndex = ctx.parameters.get("index"), let index = Int(rawIndex) else { throw HTTPError(.badRequest) }
        var mutable = request
        let buffer = try await mutable.collectBody(upTo: MultimodalIngestionService.chunkSize)
        try await service.uploadChunk(tenantID: tenantID, batchID: batchID, itemID: itemID, index: index, data: Data(buffer: buffer))
        return .noContent
    }

    @Sendable private func complete(_: Request, ctx: AppRequestContext) async throws -> IngestionBatchDTO {
        try await service.complete(
            tenantID: ctx.requireTenantID(), batchID: parameter("batchID", ctx: ctx), itemID: parameter("itemID", ctx: ctx)
        )
    }

    @Sendable private func retry(_: Request, ctx: AppRequestContext) async throws -> IngestionBatchDTO {
        try await service.retry(
            tenantID: ctx.requireTenantID(), batchID: parameter("batchID", ctx: ctx), itemID: parameter("itemID", ctx: ctx)
        )
    }

    @Sendable private func cancel(_: Request, ctx: AppRequestContext) async throws -> IngestionBatchDTO {
        try await service.cancel(
            tenantID: ctx.requireTenantID(), batchID: parameter("batchID", ctx: ctx), itemID: parameter("itemID", ctx: ctx)
        )
    }

    private func parameter(_ name: String, ctx: AppRequestContext) throws -> UUID {
        guard let raw = ctx.parameters.get(name), let id = UUID(uuidString: raw) else { throw HTTPError(.badRequest, message: "invalid \(name)") }
        return id
    }
}
