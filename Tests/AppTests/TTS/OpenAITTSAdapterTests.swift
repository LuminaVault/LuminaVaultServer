@testable import App
import Foundation
import Logging
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-204 — unit tests for the OpenAI TTS adapter. URLProtocol stub
/// intercepts the outbound `POST /v1/audio/speech` so the suite exercises
/// request shaping (URL, method, headers, JSON body, voice mapping) and
/// response classification (`200` → audio bytes, `429` → transient,
/// `400` → permanent) without hitting the real OpenAI network.
@Suite(.serialized)
struct OpenAITTSAdapterTests {
    // MARK: - URLProtocol stub

    /// Concurrency-safe per-test handler injection. Each test installs its
    /// own response handler before kicking off a request; `setHandler(nil)`
    /// resets in `defer` so leaks across tests can't happen.
    nonisolated(unsafe) private final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with _: URLRequest) -> Bool { handler != nil }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private static func stubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    private static let logger = Logger(label: "test.tts.openai")

    // MARK: - Tests

    @Test
    func `200 response returns audio data with correct content type`() async throws {
        StubProtocol.handler = { request in
            // Verify request shape inline so we don't need to thread state out.
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/speech")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"],
            )!
            return (response, Data([0xFF, 0xFB, 0x90, 0x44])) // MP3 sync word + header
        }
        defer { StubProtocol.handler = nil }

        let adapter = OpenAITTSAdapter(
            apiKey: "sk-test",
            defaultModel: "tts-1",
            session: Self.stubSession(),
            logger: Self.logger,
        )
        let result = try await adapter.synthesize(text: "Hello", voice: "lumina", modelID: nil)

        #expect(result.contentType == "audio/mpeg")
        #expect(result.charactersBilled == 5)
        #expect(result.audioData.count == 4)
        #expect(result.audioData.first == 0xFF)
    }

    @Test
    func `request body carries lumina-to-alloy mapping and mp3 response_format`() async throws {
        StubProtocol.handler = { request in
            let body = request.httpBody ?? (request.httpBodyStream.map { Data(reading: $0) } ?? Data())
            let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            #expect(parsed["model"] as? String == "tts-1")
            #expect(parsed["input"] as? String == "Speak this")
            #expect(parsed["voice"] as? String == "alloy")
            #expect(parsed["response_format"] as? String == "mp3")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data([0xFF]))
        }
        defer { StubProtocol.handler = nil }

        let adapter = OpenAITTSAdapter(
            apiKey: "sk-test",
            defaultModel: "tts-1",
            session: Self.stubSession(),
            logger: Self.logger,
        )
        _ = try await adapter.synthesize(text: "Speak this", voice: "lumina", modelID: nil)
    }

    @Test
    func `429 maps to ProviderError transient`() async throws {
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (response, Data("rate limited".utf8))
        }
        defer { StubProtocol.handler = nil }

        let adapter = OpenAITTSAdapter(apiKey: "sk-test", session: Self.stubSession(), logger: Self.logger)
        await #expect(throws: ProviderError.self) {
            _ = try await adapter.synthesize(text: "Hi", voice: "lumina", modelID: nil)
        }
    }

    @Test
    func `400 maps to ProviderError permanent (non-recoverable)`() async throws {
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (response, Data("bad request".utf8))
        }
        defer { StubProtocol.handler = nil }

        let adapter = OpenAITTSAdapter(apiKey: "sk-test", session: Self.stubSession(), logger: Self.logger)
        do {
            _ = try await adapter.synthesize(text: "Hi", voice: "lumina", modelID: nil)
            Issue.record("expected throw")
        } catch let providerError as ProviderError {
            #expect(!providerError.isRecoverable)
            #expect(providerError.provider == .openai)
        } catch {
            Issue.record("expected ProviderError, got \(error)")
        }
    }

    @Test
    func `unknown voice falls through to alloy`() async throws {
        StubProtocol.handler = { request in
            let body = request.httpBody ?? Data()
            let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            #expect(parsed["voice"] as? String == "alloy")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        defer { StubProtocol.handler = nil }

        let adapter = OpenAITTSAdapter(apiKey: "sk-test", session: Self.stubSession(), logger: Self.logger)
        _ = try await adapter.synthesize(text: "hi", voice: "wholly-unknown-voice", modelID: nil)
    }
}

private extension Data {
    /// Drains an InputStream into Data. Body streams can replace `httpBody`
    /// when the URLSession reroutes large payloads; the stub honours both.
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        let bufSize = 4096
        var buf = [UInt8](repeating: 0, count: bufSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: bufSize)
            if read <= 0 { break }
            append(buf, count: read)
        }
    }
}
