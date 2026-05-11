import Foundation
import Logging
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import App

/// HER-136 test coverage for `SMSSender` family.
///
/// `LoggingSMSSender` — no network. Smoke test only.
/// `TwilioSMSSender`  — exercises the URLSession path via a `URLProtocol`
///                      stub so we never hit the real Twilio API.
///
/// `.serialized` because the URLProtocol stub uses a static handler — running
/// in parallel would let one test's response satisfy another test's request.
@Suite(.serialized)
struct SMSSenderTests {
    // MARK: - LoggingSMSSender

    @Test
    func `logging sender does not throw`() async throws {
        let sender = LoggingSMSSender(logger: Logger(label: "test.sms.logging"))
        // No expectations beyond "doesn't blow up" — the impl just logs.
        try await sender.send(code: "123456", to: "+15555550100", purpose: "login")
    }

    // MARK: - RecordingSMSSender (also re-usable from other suites)

    @Test
    func `recording sender captures every call`() async throws {
        let recorder = RecordingSMSSender()
        try await recorder.send(code: "111111", to: "+15555550101", purpose: "login")
        try await recorder.send(code: "222222", to: "+15555550102", purpose: "verify")

        let history = await recorder.history
        #expect(history.count == 2)
        #expect(history[0] == .init(code: "111111", to: "+15555550101", purpose: "login"))
        #expect(history[1] == .init(code: "222222", to: "+15555550102", purpose: "verify"))

        let last = await recorder.last
        #expect(last?.code == "222222")
    }

    // MARK: - TwilioSMSSender

    @Test
    func `twilio sender posts correct request`() async throws {
        let captured = CapturedRequest()
        StubURLProtocol.handler = { req in
            await captured.set(req)
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil,
            )!
            return (resp, Data())
        }
        defer { StubURLProtocol.handler = nil }

        let sender = TwilioSMSSender(
            accountSID: "ACfake",
            authToken: "secret",
            fromNumber: "+15555550000",
            session: Self.makeStubSession(),
            logger: Logger(label: "test.twilio"),
        )
        try await sender.send(code: "424242", to: "+15555550199", purpose: "login")

        let req = try #require(await captured.value)
        #expect(req.url?.absoluteString == "https://api.twilio.com/2010-04-01/Accounts/ACfake/Messages.json")
        #expect(req.httpMethod == "POST")

        let auth = req.value(forHTTPHeaderField: "Authorization")
        // Authorization: Basic base64(SID:token)
        let expectedAuth = "Basic " + "ACfake:secret".data(using: .utf8)!.base64EncodedString()
        #expect(auth == expectedAuth)
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")

        let body = try #require(req.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        // The body is `&`-joined key=value with percent-encoding; verify each
        // field independently so order doesn't matter.
        let pairs = body.split(separator: "&").map(String.init)
        #expect(pairs.contains(where: { $0.contains("To=") && $0.contains("%2B15555550199") }))
        #expect(pairs.contains(where: { $0.contains("From=") && $0.contains("%2B15555550000") }))
        #expect(pairs.contains(where: { $0.hasPrefix("Body=") && $0.contains("424242") }))
    }

    @Test
    func `twilio sender throws when unconfigured`() async throws {
        let sender = TwilioSMSSender(
            accountSID: "",
            authToken: "",
            fromNumber: "",
            session: Self.makeStubSession(),
            logger: Logger(label: "test.twilio"),
        )
        await #expect(throws: (any Error).self) {
            try await sender.send(code: "1", to: "+15555550000", purpose: "login")
        }
    }

    @Test
    func `twilio sender throws on non 2 xx`() async throws {
        StubURLProtocol.handler = { req in
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil,
            )!
            return (resp, Data(#"{"message":"bad creds"}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let sender = TwilioSMSSender(
            accountSID: "ACfake",
            authToken: "wrong",
            fromNumber: "+15555550000",
            session: Self.makeStubSession(),
            logger: Logger(label: "test.twilio"),
        )
        await #expect(throws: (any Error).self) {
            try await sender.send(code: "1", to: "+15555550199", purpose: "login")
        }
    }

    // MARK: - Stub helpers

    private static func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - Reusable test doubles

/// Captures every `send(...)` call so suites that drive Phone-OTP / verify
/// flows can assert what reached the SMS layer.
actor RecordingSMSSender: SMSSender {
    struct Sent: Equatable {
        let code: String
        let to: String
        let purpose: String
    }

    private(set) var history: [Sent] = []
    var last: Sent? {
        history.last
    }

    func send(code: String, to phone: String, purpose: String) async throws {
        history.append(Sent(code: code, to: phone, purpose: purpose))
    }
}

/// Stores the `URLRequest` the system under test handed to URLSession.
actor CapturedRequest {
    private(set) var value: URLRequest?
    func set(_ req: URLRequest) {
        value = req
    }
}

/// URLProtocol stub that lets a test inject a custom response for any
/// request. The handler is async so capture actors can store the request.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "StubURLProtocol", code: -1))
            return
        }
        nonisolated(unsafe) let request = request
        nonisolated(unsafe) let client = client
        nonisolated(unsafe) let proto = self
        Task {
            do {
                let (response, data) = try await handler(request)
                client?.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(proto, didLoad: data)
                client?.urlProtocolDidFinishLoading(proto)
            } catch {
                client?.urlProtocol(proto, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}
