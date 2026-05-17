import Foundation
import Logging
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import App

/// HER-33 production email sender. Posts the OTP code as a single
/// transactional email via the Resend HTTP API
/// (`POST https://api.resend.com/emails`). Auth is `Authorization: Bearer
/// <apiKey>`; body is JSON.
///
/// `.serialized` orders tests within this suite. The dedicated
/// `ResendStubURLProtocol` (own static handler) avoids races with
/// `SMSSenderTests`, which also drives `StubURLProtocol` in parallel.
@Suite(.serialized)
struct ResendEmailOTPSenderTests {
    @Test
    func `posts JSON body with code, from, to, subject`() async throws {
        let captured = CapturedRequest()
        ResendStubURLProtocol.handler = { req in
            await captured.set(req)
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"],
            )!
            return (resp, Data(#"{"id":"em_abc"}"#.utf8))
        }
        defer { ResendStubURLProtocol.handler = nil }

        let sender = ResendEmailOTPSender(
            apiKey: "re_test_key",
            fromAddress: "LuminaVault <auth@lumina.app>",
            replyTo: "support@lumina.app",
            session: Self.makeStubSession(),
            logger: Logger(label: "test.resend"),
        )
        try await sender.send(code: "424242", to: "user@example.com", purpose: "login")

        let req = try #require(await captured.value)
        #expect(req.url?.absoluteString == "https://api.resend.com/emails")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer re_test_key")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(req.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["from"] as? String == "LuminaVault <auth@lumina.app>")
        #expect(json["reply_to"] as? String == "support@lumina.app")
        let to = try #require(json["to"] as? [String])
        #expect(to == ["user@example.com"])
        let subject = try #require(json["subject"] as? String)
        #expect(subject.contains("LuminaVault"))
        // Code MUST appear in both text and html so providers without an HTML
        // renderer (or aggressive plain-text fallbacks) still surface it.
        let text = try #require(json["text"] as? String)
        let html = try #require(json["html"] as? String)
        #expect(text.contains("424242"))
        #expect(html.contains("424242"))
    }

    @Test
    func `omits reply_to when not configured`() async throws {
        let captured = CapturedRequest()
        ResendStubURLProtocol.handler = { req in
            await captured.set(req)
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil,
            )!
            return (resp, Data(#"{"id":"em_abc"}"#.utf8))
        }
        defer { ResendStubURLProtocol.handler = nil }

        let sender = ResendEmailOTPSender(
            apiKey: "re_test_key",
            fromAddress: "auth@lumina.app",
            replyTo: "",
            session: Self.makeStubSession(),
            logger: Logger(label: "test.resend"),
        )
        try await sender.send(code: "111111", to: "user@example.com", purpose: "verify")

        let req = try #require(await captured.value)
        let body = try #require(req.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["reply_to"] == nil)
    }

    @Test
    func `throws when API key empty`() async throws {
        let sender = ResendEmailOTPSender(
            apiKey: "",
            fromAddress: "auth@lumina.app",
            replyTo: "",
            session: Self.makeStubSession(),
            logger: Logger(label: "test.resend"),
        )
        await #expect(throws: (any Error).self) {
            try await sender.send(code: "1", to: "user@example.com", purpose: "login")
        }
    }

    @Test
    func `throws when from address empty`() async throws {
        let sender = ResendEmailOTPSender(
            apiKey: "re_test_key",
            fromAddress: "",
            replyTo: "",
            session: Self.makeStubSession(),
            logger: Logger(label: "test.resend"),
        )
        await #expect(throws: (any Error).self) {
            try await sender.send(code: "1", to: "user@example.com", purpose: "login")
        }
    }

    @Test
    func `throws on non 2xx response`() async throws {
        ResendStubURLProtocol.handler = { req in
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 422, httpVersion: "HTTP/1.1", headerFields: nil,
            )!
            return (resp, Data(#"{"name":"validation_error","message":"unverified sender"}"#.utf8))
        }
        defer { ResendStubURLProtocol.handler = nil }

        let sender = ResendEmailOTPSender(
            apiKey: "re_test_key",
            fromAddress: "auth@lumina.app",
            replyTo: "",
            session: Self.makeStubSession(),
            logger: Logger(label: "test.resend"),
        )
        await #expect(throws: (any Error).self) {
            try await sender.send(code: "1", to: "user@example.com", purpose: "login")
        }
    }

    // MARK: - Stub helpers

    private static func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResendStubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

/// Separate class from `StubURLProtocol` (which `SMSSenderTests` owns) so
/// the two suites' static handlers don't race when running in parallel.
final class ResendStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "ResendStubURLProtocol", code: -1))
            return
        }
        let captured = Self.reconstituteBody(from: request)
        nonisolated(unsafe) let client = client
        nonisolated(unsafe) let proto = self
        Task {
            do {
                let (response, data) = try await handler(captured)
                client?.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(proto, didLoad: data)
                client?.urlProtocolDidFinishLoading(proto)
            } catch {
                client?.urlProtocol(proto, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}

    private static func reconstituteBody(from request: URLRequest) -> URLRequest {
        if request.httpBody != nil { return request }
        guard let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        var copy = request
        copy.httpBody = data
        return copy
    }
}
