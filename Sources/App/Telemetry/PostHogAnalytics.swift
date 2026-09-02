import Synchronization

/// Destination for product analytics events. `PostHogHTTPClient` is the
/// production conformer; tests install a recording fake.
protocol AnalyticsSink: Sendable {
    /// Non-blocking, never throws — analytics must not back-pressure a request.
    func capture(_ event: String, distinctID: String?, properties: [String: any Sendable])
}

/// Process-wide analytics seam used by controllers. Events are dropped until
/// `install` runs (boot wires a `PostHogHTTPClient` when `POSTHOG_PROJECT_TOKEN`
/// and `POSTHOG_HOST` are set); call sites never need to know whether
/// analytics is configured.
enum PostHogAnalytics {
    private static let sink = Mutex<(any AnalyticsSink)?>(nil)

    /// Installs (or, with `nil`, removes) the process-wide sink.
    static func install(_ newSink: (any AnalyticsSink)?) {
        sink.withLock { $0 = newSink }
    }

    static func capture(_ event: String, distinctID: String? = nil, properties: [String: any Sendable] = [:]) {
        let current = sink.withLock { $0 }
        current?.capture(event, distinctID: distinctID, properties: properties)
    }
}
