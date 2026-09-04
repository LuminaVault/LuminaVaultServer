import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

/// HTTP seam for `HermesRunsClient` so the gateway contract is testable
/// without sockets. Bodies are exposed as a chunk stream because the
/// `/events` endpoint is a long-lived SSE response; unary calls collect it.
protocol HermesRunsHTTPExecuting: Sendable {
    func execute(_ request: HTTPClientRequest, timeout: TimeAmount) async throws -> HermesRunsHTTPResponse
}

struct HermesRunsHTTPResponse: Sendable {
    let status: UInt
    let body: AsyncThrowingStream<ByteBuffer, Error>

    var isSuccess: Bool {
        (200 ..< 300).contains(status)
    }

    /// Drain the body into one buffer, failing past `maxBytes`.
    func collect(maxBytes: Int) async throws -> ByteBuffer {
        var collected = ByteBuffer()
        for try await chunk in body {
            var chunk = chunk
            collected.writeBuffer(&chunk)
            if collected.readableBytes > maxBytes {
                throw HermesRunsClientError.responseTooLarge(limit: maxBytes)
            }
        }
        return collected
    }
}

/// Production transport on the no-redirect `BYOHTTP.httpClient` (BYO
/// endpoints must never bounce a bearer through a redirect).
struct AsyncHTTPClientHermesRunsHTTP: HermesRunsHTTPExecuting {
    let httpClient: HTTPClient

    init(httpClient: HTTPClient = BYOHTTP.httpClient) {
        self.httpClient = httpClient
    }

    func execute(_ request: HTTPClientRequest, timeout: TimeAmount) async throws -> HermesRunsHTTPResponse {
        let response = try await httpClient.execute(request, timeout: timeout)
        let (stream, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
        let pump = Task {
            do {
                for try await chunk in response.body {
                    if Task.isCancelled {
                        break
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in pump.cancel() }
        return HermesRunsHTTPResponse(status: response.status.code, body: stream)
    }
}
