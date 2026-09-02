@testable import App
import Foundation
import Logging
import NIOCore
import Testing

/// P0 #4 — the server-side PostHog HTTP client batches and posts the JSON
/// shape `POST /capture` expects, and stays a no-op when unconfigured.
struct PostHogHTTPClientTests {
    private static let logger = Logger(label: "test.posthog")

    /// Records every body posted, and can be told to fail or reject.
    private final class RecordingTransport: PostHogTransport, @unchecked Sendable {
        // `@unchecked`: all state lives behind `lock`; the class is a test double.
        private let lock = NSLock()
        private var posted: [(url: String, body: Data)] = []
        private let status: UInt
        private let failure: (any Error)?

        init(status: UInt = 200, failure: (any Error)? = nil) {
            self.status = status
            self.failure = failure
        }

        func post(url: String, body: ByteBuffer) async throws -> UInt {
            if let failure {
                throw failure
            }
            lock.withLock { posted.append((url, Data(buffer: body))) }
            return status
        }

        var requests: [(url: String, body: Data)] {
            lock.withLock { posted }
        }

        func batches() throws -> [[String: Any]] {
            try requests.map { request in
                let object = try JSONSerialization.jsonObject(with: request.body)
                return try #require(object as? [String: Any])
            }
        }
    }

    private struct StubError: Error {}

    @Test
    func `capture URL is derived from the host`() {
        #expect(PostHogHTTPClient.captureURL(host: "https://eu.i.posthog.com") == "https://eu.i.posthog.com/capture")
        #expect(PostHogHTTPClient.captureURL(host: "https://eu.i.posthog.com/") == "https://eu.i.posthog.com/capture")
        #expect(PostHogHTTPClient.captureURL(host: " https://ph.example.com/capture ") == "https://ph.example.com/capture")
    }

    @Test
    func `flush posts one batch with api_key, distinct_id, timestamp and $lib`() async throws {
        let transport = RecordingTransport()
        let client = PostHogHTTPClient(
            apiKey: "phc_test",
            host: "https://eu.i.posthog.com",
            transport: transport,
            logger: Self.logger
        )
        client.capture("user_registered", distinctID: "user-1", properties: ["auth_method": "password"])
        client.capture("user_logged_in", distinctID: nil, properties: ["mfa_required": true, "grounded_hits": 3])
        #expect(client.pendingCount == 2)

        await client.flush()

        #expect(client.pendingCount == 0)
        let requests = transport.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url == "https://eu.i.posthog.com/capture")
        let payload = try #require(try transport.batches().first)
        #expect(payload["api_key"] as? String == "phc_test")
        let batch = try #require(payload["batch"] as? [[String: Any]])
        #expect(batch.count == 2)

        let first = batch[0]
        #expect(first["event"] as? String == "user_registered")
        #expect(first["distinct_id"] as? String == "user-1")
        let firstProperties = try #require(first["properties"] as? [String: Any])
        #expect(firstProperties["auth_method"] as? String == "password")
        #expect(firstProperties["$lib"] as? String == "luminavault-server")
        let timestamp = try #require(first["timestamp"] as? String)
        #expect(timestamp.hasSuffix("Z"))
        #expect(timestamp.contains("T"))

        let second = batch[1]
        #expect(second["distinct_id"] as? String == "luminavault-server")
        let secondProperties = try #require(second["properties"] as? [String: Any])
        #expect(secondProperties["mfa_required"] as? Bool == true)
        #expect((secondProperties["grounded_hits"] as? NSNumber)?.intValue == 3)
    }

    @Test
    func `flush splits the queue into maxBatchSize posts`() async throws {
        let transport = RecordingTransport()
        let client = PostHogHTTPClient(
            apiKey: "phc_test",
            host: "https://ph.example.com",
            transport: transport,
            maxBatchSize: 3,
            logger: Self.logger
        )
        for index in 0 ..< 7 {
            client.capture("event_\(index)", distinctID: nil, properties: [:])
        }
        await client.flush()
        let batches = try transport.batches().map { try #require($0["batch"] as? [[String: Any]]) }
        #expect(batches.map(\.count) == [3, 3, 1])
        #expect(batches.flatMap(\.self).compactMap { $0["event"] as? String } == (0 ..< 7).map { "event_\($0)" })
        #expect(client.pendingCount == 0)
    }

    @Test
    func `queue is bounded and overflow drops new events`() async throws {
        let transport = RecordingTransport()
        let client = PostHogHTTPClient(
            apiKey: "phc_test",
            host: "https://ph.example.com",
            transport: transport,
            maxBatchSize: 2,
            maxQueueDepth: 2,
            logger: Self.logger
        )
        client.capture("kept_1", distinctID: nil, properties: [:])
        client.capture("kept_2", distinctID: nil, properties: [:])
        client.capture("dropped", distinctID: nil, properties: [:])
        #expect(client.pendingCount == 2)
        await client.flush()
        let events = try transport.batches().flatMap { try #require($0["batch"] as? [[String: Any]]) }
        #expect(events.compactMap { $0["event"] as? String } == ["kept_1", "kept_2"])
    }

    @Test
    func `transport failures drop the batch without throwing`() async {
        let transport = RecordingTransport(failure: StubError())
        let client = PostHogHTTPClient(
            apiKey: "phc_test",
            host: "https://ph.example.com",
            transport: transport,
            logger: Self.logger
        )
        client.capture("lost", distinctID: nil, properties: [:])
        await client.flush()
        #expect(client.pendingCount == 0)
        #expect(transport.requests.isEmpty)
    }

    @Test
    func `run flushes on cancellation`() async throws {
        let transport = RecordingTransport()
        let client = PostHogHTTPClient(
            apiKey: "phc_test",
            host: "https://ph.example.com",
            transport: transport,
            flushInterval: .seconds(3600),
            logger: Self.logger
        )
        client.capture("before_shutdown", distinctID: nil, properties: [:])
        let service = Task { try await client.run() }
        try await Task.sleep(for: .milliseconds(50))
        service.cancel()
        _ = await service.result
        let events = try transport.batches().flatMap { try #require($0["batch"] as? [[String: Any]]) }
        #expect(events.compactMap { $0["event"] as? String } == ["before_shutdown"])
    }

    @Test
    func `factory returns nil when the token or host is absent`() {
        #expect(makePostHogAnalytics(projectToken: "", host: "https://ph.example.com", logger: Self.logger) == nil)
        #expect(makePostHogAnalytics(projectToken: "phc_x", host: "  ", logger: Self.logger) == nil)
        let client = makePostHogAnalytics(projectToken: " phc_x ", host: "https://ph.example.com/", logger: Self.logger)
        #expect(client?.captureURL == "https://ph.example.com/capture")
    }

    @Test
    func `PostHogAnalytics is a no-op without an installed sink and forwards with one`() async throws {
        PostHogAnalytics.install(nil)
        PostHogAnalytics.capture("ignored", properties: ["k": "v"])

        let transport = RecordingTransport()
        let client = PostHogHTTPClient(apiKey: "phc_test", host: "https://ph.example.com", transport: transport, logger: Self.logger)
        PostHogAnalytics.install(client)
        defer { PostHogAnalytics.install(nil) }
        PostHogAnalytics.capture("forwarded", distinctID: "u", properties: ["has_space": false])
        #expect(client.pendingCount == 1)
        await client.flush()
        let events = try transport.batches().flatMap { try #require($0["batch"] as? [[String: Any]]) }
        #expect(events.compactMap { $0["event"] as? String } == ["forwarded"])
    }

    @Test
    func `JSONValue bridges loosely typed property values`() {
        #expect(JSONValue(anySendable: "s") == .string("s"))
        #expect(JSONValue(anySendable: 3) == .number(3))
        #expect(JSONValue(anySendable: 1.5) == .number(1.5))
        #expect(JSONValue(anySendable: true) == .bool(true))
        let uuid = UUID()
        #expect(JSONValue(anySendable: uuid) == .string(uuid.uuidString))
        #expect(JSONValue(anySendable: ["a", 1] as [any Sendable]) == .array([.string("a"), .number(1)]))
        #expect(JSONValue(anySendable: ["k": true] as [String: any Sendable]) == .object(["k": .bool(true)]))
        let missing: String? = nil
        #expect(JSONValue(anySendable: missing as (any Sendable)?) == .null)
    }
}
