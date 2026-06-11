import Crypto
import FluentKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdFluent
import Logging
import NIOCore

/// HER-39 — request-level idempotency for mutating endpoints. Clients (the iOS
/// sync queue) attach `Idempotency-Key: <UUIDv4>` to any mutating request they
/// might retry after a network drop. Server stores the response of the first
/// successful execution under `(tenant_id, key)`; subsequent retries with the
/// same key replay the cached response instead of re-executing the handler.
///
/// Contract:
/// - Header missing → middleware is a no-op (current behavior preserved).
/// - Cache hit + matching request hash + not expired → cached response replayed.
/// - Cache hit + mismatched request hash → 409 Conflict (caller bug).
/// - Cache miss → handler runs; on any 2xx/4xx response we capture and persist
///   the result. 5xx responses are NOT cached so the client's retry can pick up
///   a healed server.
/// - Response bodies larger than `maxResponseBodyBytes` are forwarded but not
///   persisted (the middleware degrades to a pass-through cache miss).
struct IdempotencyMiddleware: RouterMiddleware {
    typealias Context = AppRequestContext

    let fluent: Fluent
    let logger: Logger

    /// 24 h matches the iOS sync queue's longest plausible backoff window.
    let ttl: TimeInterval

    /// 32 MiB covers single-file vault uploads (HEIC photos cap below 10 MB in
    /// practice). Requests larger than this skip idempotency entirely — the
    /// retry will re-execute, and natural upsert/delete idempotency on the
    /// underlying endpoints prevents user-visible duplication.
    let maxRequestBodyBytes: Int

    /// 1 MiB covers every JSON response shape the server currently emits on
    /// idempotency-protected routes (compile, upload, move return small JSON;
    /// delete returns 204). Larger responses are not cached but still
    /// forwarded.
    let maxResponseBodyBytes: Int

    init(
        fluent: Fluent,
        logger: Logger = Logger(label: "lv.idempotency"),
        ttl: TimeInterval = 24 * 3600,
        maxRequestBodyBytes: Int = 32 * 1024 * 1024,
        maxResponseBodyBytes: Int = 1 * 1024 * 1024
    ) {
        self.fluent = fluent
        self.logger = logger
        self.ttl = ttl
        self.maxRequestBodyBytes = maxRequestBodyBytes
        self.maxResponseBodyBytes = maxResponseBodyBytes
    }

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let headerName = HTTPField.Name("Idempotency-Key"),
              let rawHeader = request.headers[headerName],
              let key = UUID(uuidString: rawHeader)
        else {
            return try await next(request, context)
        }

        let tenantID = try context.requireTenantID()
        let db = fluent.db()

        // Buffer the request body so we can both hash it and replay it to the
        // downstream handler.
        var mutableRequest = request
        let collected: ByteBuffer
        do {
            collected = try await mutableRequest.collectBody(upTo: maxRequestBodyBytes)
        } catch {
            logger.debug("idempotency: body too large, bypassing", metadata: ["key": "\(key)"])
            return try await next(request, context)
        }

        let requestHash = Self.hash(
            body: collected,
            method: request.method.rawValue,
            path: request.uri.path
        )

        // Tenant-scoped lookup: a tenant cannot see another tenant's cached
        // response even with the same key.
        if let existing = try await IdempotencyKey.query(on: db, tenantID: tenantID)
            .filter(\.$key == key)
            .first()
        {
            if existing.expiresAt <= Date() {
                try? await existing.delete(on: db)
            } else if existing.requestHash != requestHash {
                logger.warning("idempotency: key reused with different body", metadata: [
                    "tenant": "\(tenantID)",
                    "key": "\(key)",
                ])
                throw HTTPError(.conflict, message: "Idempotency-Key reused with different request")
            } else {
                logger.debug("idempotency: replay", metadata: ["tenant": "\(tenantID)", "key": "\(key)"])
                return Self.response(from: existing)
            }
        }

        // Re-attach the buffered body so the downstream handler sees it.
        var replayRequest = request
        replayRequest.body = .init(buffer: collected)
        let response = try await next(replayRequest, context)

        // Don't cache 5xx — caller's retry should pick up a healed server.
        let shouldPersist = (200 ..< 500).contains(response.status.code) && response.status.code != 408

        // Collect the response body via a writer so the body is preserved for
        // both forwarding and (when eligible) persistence. `ResponseBody`
        // exposes its bytes only through `write(_:)`, so we install a
        // collector and rebuild a new buffered ResponseBody from the result.
        let collector = ResponseBodyCollector()
        try await response.body.write(BufferingWriter(collector: collector))
        let responseBuffer = collector.buffer

        if shouldPersist, responseBuffer.readableBytes <= maxResponseBodyBytes {
            let bodyData = Data(buffer: responseBuffer)
            let row = IdempotencyKey(
                tenantID: tenantID,
                key: key,
                requestHash: requestHash,
                responseStatus: Int(response.status.code),
                responseContentType: response.headers[.contentType],
                responseBody: bodyData,
                expiresAt: Date().addingTimeInterval(ttl)
            )
            do {
                try await row.create(on: db)
            } catch {
                // Race: concurrent retry created the row first. We still own
                // a valid response; just return it. Future replays hit cache.
                logger.debug("idempotency: persistence race, returning live response", metadata: [
                    "error": "\(error)",
                ])
            }
        }

        return Response(status: response.status, headers: response.headers, body: .init(byteBuffer: responseBuffer))
    }

    private static func hash(body: ByteBuffer, method: String, path: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(body.readableBytesView))
        hasher.update(data: Data(method.utf8))
        hasher.update(data: Data(path.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func response(from row: IdempotencyKey) -> Response {
        var headers: HTTPFields = [:]
        if let ct = row.responseContentType {
            headers[.contentType] = ct
        }
        if let replayName = HTTPField.Name("Idempotent-Replayed") {
            headers[replayName] = "true"
        }
        return Response(
            status: .init(code: row.responseStatus),
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: row.responseBody))
        )
    }
}

/// Reference-typed collector so the buffer survives the consuming
/// `BufferingWriter` once `ResponseBody.write` consumes it.
private final class ResponseBodyCollector: @unchecked Sendable {
    var buffer = ByteBuffer()
}

private struct BufferingWriter: ResponseBodyWriter {
    let collector: ResponseBodyCollector

    mutating func write(_ buffer: ByteBuffer) async throws {
        var b = buffer
        collector.buffer.writeBuffer(&b)
    }

    consuming func finish(_: HTTPFields?) async throws {}
}
