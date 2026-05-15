import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-226 — gateway-reachability probe for the Hermes admin health
/// endpoint. Calls `GET <gatewayURL>/v1/models` with a 1 s timeout so
/// the chat hot path (`/v1/llm/chat`) is never affected by a hung
/// gateway. Results are cached for 30 s per gateway URL so the admin
/// dashboard can refresh aggressively without producing additional
/// outbound traffic.
actor HermesGatewayProbe {
    struct ProbeResult: Sendable {
        let reachable: Bool
        let latencyMs: Int?
        let checkedAt: Date
    }

    private struct CacheEntry {
        let result: ProbeResult
    }

    private let session: URLSession
    private let logger: Logger
    private let timeout: TimeInterval
    private let ttl: TimeInterval
    private var cache: [String: CacheEntry] = [:]

    init(
        session: URLSession = .shared,
        logger: Logger,
        timeout: TimeInterval = 1.0,
        ttl: TimeInterval = 30.0,
    ) {
        self.session = session
        self.logger = logger
        self.timeout = timeout
        self.ttl = ttl
    }

    /// Returns a fresh probe if the cached entry is older than `ttl`,
    /// otherwise returns the cached value verbatim. Treat any HTTP
    /// response (2xx/3xx/4xx) as reachable — a 404 still proves the
    /// upstream is alive. Only network-layer failures + non-HTTP
    /// responses flip `reachable` to false.
    func probe(gatewayURL: String, now: Date = Date()) async -> ProbeResult {
        if let cached = cache[gatewayURL], now.timeIntervalSince(cached.result.checkedAt) < ttl {
            return cached.result
        }
        let result = await runProbe(gatewayURL: gatewayURL, now: now)
        cache[gatewayURL] = CacheEntry(result: result)
        return result
    }

    /// Test/diagnostic — drop every cached entry. Production code should
    /// rely on TTL expiry rather than calling this.
    func invalidate() {
        cache.removeAll()
    }

    private func runProbe(gatewayURL: String, now: Date) async -> ProbeResult {
        guard let url = URL(string: gatewayURL)?.appendingPathComponent("v1").appendingPathComponent("models") else {
            logger.warning("hermes.probe invalid gateway URL: \(gatewayURL)")
            return ProbeResult(reachable: false, latencyMs: nil, checkedAt: now)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        let start = ContinuousClock.now
        do {
            let (_, response) = try await session.data(for: req)
            let elapsed = ContinuousClock.now - start
            let latencyMs = Self.elapsedMilliseconds(elapsed)
            let reachable = (response as? HTTPURLResponse) != nil
            return ProbeResult(reachable: reachable, latencyMs: latencyMs, checkedAt: now)
        } catch {
            logger.debug("hermes.probe failed url=\(gatewayURL) err=\(error)")
            return ProbeResult(reachable: false, latencyMs: nil, checkedAt: now)
        }
    }

    private static func elapsedMilliseconds(_ duration: Duration) -> Int {
        let seconds = Int(duration.components.seconds * 1_000)
        let frac = Int(duration.components.attoseconds / 1_000_000_000_000_000)
        return max(0, seconds + frac)
    }
}
