import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOFoundationCompat
import ServiceLifecycle
import Synchronization

/// One analytics event as PostHog's `/capture` batch endpoint expects it.
struct PostHogEvent: Encodable, Sendable, Equatable {
    let event: String
    let distinctID: String
    let timestamp: String
    let properties: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case event
        case distinctID = "distinct_id"
        case timestamp
        case properties
    }
}

/// Wire envelope for `POST {host}/capture` in batch form.
struct PostHogBatchRequest: Encodable, Sendable {
    let apiKey: String
    let batch: [PostHogEvent]

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case batch
    }
}

/// Transport seam so tests can capture the exact bytes posted without a
/// socket. Production uses `AsyncHTTPClientPostHogTransport`.
protocol PostHogTransport: Sendable {
    /// Posts `body` as JSON to `url`; returns the HTTP status code.
    func post(url: String, body: ByteBuffer) async throws -> UInt
}

struct AsyncHTTPClientPostHogTransport: PostHogTransport {
    let httpClient: HTTPClient
    let timeout: TimeAmount

    init(httpClient: HTTPClient = .shared, timeout: TimeAmount = .seconds(10)) {
        self.httpClient = httpClient
        self.timeout = timeout
    }

    func post(url: String, body: ByteBuffer) async throws -> UInt {
        var request = HTTPClientRequest(url: url)
        request.method = .POST
        request.headers.add(name: "content-type", value: "application/json")
        request.headers.add(name: "user-agent", value: "luminavault-server")
        request.body = .bytes(body)
        let response = try await httpClient.execute(request, timeout: timeout)
        return response.status.code
    }
}

/// P0 #4 — server-side PostHog capture that works on Linux.
///
/// `posthog-ios` is an ObjC SDK that only links on Darwin, so every
/// `PostHogAnalytics.capture` on the deployed (Linux) server was a no-op.
/// This client speaks the HTTP capture API directly: events are queued in a
/// bounded in-memory buffer by non-async `capture` calls (safe from request
/// handlers — never spawns a `Task`, never blocks), and a `ServiceLifecycle`
/// loop posts them in batches on a fixed interval. Graceful shutdown drains
/// what is left so the last events of a process are not lost.
///
/// Delivery is best-effort: a failed post logs a warning and drops that batch
/// rather than retrying, because analytics must never back-pressure the app.
final class PostHogHTTPClient: Service, AnalyticsSink, Sendable {
    private struct State {
        var queue: [PostHogEvent] = []
        var droppedSinceLastFlush = 0
    }

    let captureURL: String
    private let apiKey: String
    private let transport: any PostHogTransport
    private let flushInterval: Duration
    private let maxBatchSize: Int
    private let maxQueueDepth: Int
    private let defaultDistinctID: String
    private let logger: Logger
    private let state = Mutex(State())
    private let encoder: JSONEncoder

    init(
        apiKey: String,
        host: String,
        transport: any PostHogTransport = AsyncHTTPClientPostHogTransport(),
        flushInterval: Duration = .seconds(10),
        maxBatchSize: Int = 100,
        maxQueueDepth: Int = 2000,
        defaultDistinctID: String = "luminavault-server",
        logger: Logger
    ) {
        self.apiKey = apiKey
        captureURL = Self.captureURL(host: host)
        self.transport = transport
        self.flushInterval = flushInterval
        self.maxBatchSize = max(1, maxBatchSize)
        self.maxQueueDepth = max(self.maxBatchSize, maxQueueDepth)
        self.defaultDistinctID = defaultDistinctID
        self.logger = logger
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    /// `https://eu.i.posthog.com` → `https://eu.i.posthog.com/capture`.
    /// Tolerates a trailing slash and an already-suffixed `/capture`.
    static func captureURL(host: String) -> String {
        var base = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        if base.hasSuffix("/capture") {
            return base
        }
        return base + "/capture"
    }

    // MARK: - AnalyticsSink

    func capture(_ event: String, distinctID: String?, properties: [String: any Sendable]) {
        var encoded = properties.mapValues(JSONValue.init(anySendable:))
        encoded["$lib"] = .string("luminavault-server")
        let item = PostHogEvent(
            event: event,
            distinctID: distinctID ?? defaultDistinctID,
            timestamp: Self.timestamp(Date()),
            properties: encoded
        )
        let dropped = state.withLock { state -> Bool in
            guard state.queue.count < maxQueueDepth else {
                state.droppedSinceLastFlush += 1
                return true
            }
            state.queue.append(item)
            return false
        }
        if dropped {
            logger.debug("posthog queue full; dropped event", metadata: ["event": "\(event)"])
        }
    }

    /// Number of events waiting to be posted. Test/observability only.
    var pendingCount: Int {
        state.withLock { $0.queue.count }
    }

    // MARK: - Service

    func run() async throws {
        logger.info("posthog analytics started", metadata: [
            "endpoint": "\(captureURL)",
            "flushInterval": "\(flushInterval)",
        ])
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: flushInterval)
                    } catch {
                        break
                    }
                    await flush()
                }
            }
            group.addTask {
                try? await gracefulShutdown()
            }
            await group.next()
            group.cancelAll()
        }
        await flush()
        logger.info("posthog analytics stopped")
    }

    /// Posts every queued event in batches of `maxBatchSize`. Safe to call
    /// concurrently with `capture`.
    func flush() async {
        while true {
            let (batch, dropped) = state.withLock { state -> ([PostHogEvent], Int) in
                let count = min(maxBatchSize, state.queue.count)
                let batch = Array(state.queue.prefix(count))
                state.queue.removeFirst(count)
                let dropped = state.droppedSinceLastFlush
                state.droppedSinceLastFlush = 0
                return (batch, dropped)
            }
            if dropped > 0 {
                logger.warning("posthog queue overflowed; events dropped", metadata: ["dropped": "\(dropped)"])
            }
            guard !batch.isEmpty else { return }
            await post(batch: batch)
            if batch.count < maxBatchSize {
                return
            }
        }
    }

    private func post(batch: [PostHogEvent]) async {
        let body: ByteBuffer
        do {
            let data = try encoder.encode(PostHogBatchRequest(apiKey: apiKey, batch: batch))
            body = ByteBuffer(data: data)
        } catch {
            logger.error("posthog batch encoding failed", metadata: ["error": "\(error)"])
            return
        }
        do {
            let status = try await transport.post(url: captureURL, body: body)
            guard (200 ..< 300).contains(status) else {
                logger.warning("posthog capture rejected", metadata: [
                    "status": "\(status)",
                    "events": "\(batch.count)",
                ])
                return
            }
            logger.debug("posthog batch posted", metadata: ["events": "\(batch.count)"])
        } catch {
            logger.warning("posthog capture failed", metadata: [
                "error": "\(error)",
                "events": "\(batch.count)",
            ])
        }
    }

    /// RFC 3339 with fractional seconds, UTC — what PostHog parses.
    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// Builds the analytics client from config, or `nil` when either
/// `POSTHOG_PROJECT_TOKEN` or `POSTHOG_HOST` is absent (analytics off).
func makePostHogAnalytics(
    projectToken: String,
    host: String,
    transport: any PostHogTransport = AsyncHTTPClientPostHogTransport(),
    logger: Logger
) -> PostHogHTTPClient? {
    let token = projectToken.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty, !trimmedHost.isEmpty else {
        logger.warning("PostHog is not configured; analytics events will not be sent", metadata: [
            "config": "POSTHOG_PROJECT_TOKEN, POSTHOG_HOST",
        ])
        return nil
    }
    return PostHogHTTPClient(apiKey: token, host: trimmedHost, transport: transport, logger: logger)
}

extension JSONValue {
    /// Lossy bridge from the loosely typed property bags used at capture
    /// sites. Anything that is not a JSON scalar/collection falls back to its
    /// `String(describing:)` so an odd value never drops the whole event.
    init(anySendable value: any Sendable) {
        switch value {
        case let string as String: self = .string(string)
        case let bool as Bool: self = .bool(bool)
        case let int as Int: self = .number(Double(int))
        case let int as Int64: self = .number(Double(int))
        case let int as UInt: self = .number(Double(int))
        case let double as Double: self = .number(double)
        case let float as Float: self = .number(Double(float))
        case let json as JSONValue: self = json
        case let date as Date: self = .string(PostHogHTTPClient.timestamp(date))
        case let uuid as UUID: self = .string(uuid.uuidString)
        case let array as [any Sendable]: self = .array(array.map(JSONValue.init(anySendable:)))
        case let object as [String: any Sendable]: self = .object(object.mapValues(JSONValue.init(anySendable:)))
        case let optional as (any Sendable)?:
            if let wrapped = optional {
                self = JSONValue(anySendable: wrapped)
            } else {
                self = .null
            }
        default: self = .string(String(describing: value))
        }
    }
}
