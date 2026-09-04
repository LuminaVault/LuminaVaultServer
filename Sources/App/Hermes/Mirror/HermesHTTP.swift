import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

/// Minimal HTTP seam over `AsyncHTTPClient` so the Hermes clients (gateway
/// skills, dashboard, capability probes) are testable without sockets.
/// Production uses `AsyncHTTPClientHermesHTTP` on the shared client.
protocol HermesHTTPExecuting: Sendable {
    func execute(_ request: HTTPClientRequest, timeout: TimeAmount, maxBodyBytes: Int) async throws -> HermesHTTPResponse
}

struct HermesHTTPResponse: Sendable {
    let status: UInt
    let headers: HTTPHeaders
    let body: ByteBuffer

    var isSuccess: Bool {
        (200 ..< 300).contains(status)
    }

    var isRedirect: Bool {
        (300 ..< 400).contains(status)
    }

    var data: Data {
        Data(buffer: body)
    }

    func json() -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    func jsonObject() -> [String: Any]? {
        json() as? [String: Any]
    }
}

struct AsyncHTTPClientHermesHTTP: HermesHTTPExecuting {
    let httpClient: HTTPClient

    init(httpClient: HTTPClient = BYOHTTP.httpClient) {
        self.httpClient = httpClient
    }

    func execute(_ request: HTTPClientRequest, timeout: TimeAmount, maxBodyBytes: Int) async throws -> HermesHTTPResponse {
        let response = try await httpClient.execute(request, timeout: timeout)
        let body: ByteBuffer
        do {
            body = try await response.body.collect(upTo: maxBodyBytes)
        } catch is NIOTooManyBytesError {
            throw HermesMirrorTransportError.bodyTooLarge(path: request.url, limit: maxBodyBytes)
        }
        return HermesHTTPResponse(status: response.status.code, headers: response.headers, body: body)
    }
}
