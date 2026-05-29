import Foundation
import Logging
import Metrics
import Tracing

struct RouteTelemetry {
    let logger: Logger
    let requestCounter: Counter
    let failureCounter: Counter
    let durationTimer: Timer

    init(labelPrefix: String, logger: Logger) {
        self.logger = logger
        requestCounter = Counter(label: "luminavault.\(labelPrefix).requests")
        failureCounter = Counter(label: "luminavault.\(labelPrefix).failures")
        durationTimer = Timer(label: "luminavault.\(labelPrefix).duration")
    }

    func observe<T>(_ operation: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        requestCounter.increment()
        let started = DispatchTime.now().uptimeNanoseconds
        return try await withSpan(operation, ofKind: .server) { _ in
            do {
                let result = try await body()
                durationTimer.recordNanoseconds(Int64(DispatchTime.now().uptimeNanoseconds - started))
                logger.info("\(operation) succeeded")
                return result
            } catch {
                failureCounter.increment()
                durationTimer.recordNanoseconds(Int64(DispatchTime.now().uptimeNanoseconds - started))
                logger.error("\(operation) failed: \(String(describing: error))")
                throw error
            }
        }
    }
}

// MARK: - Structured stage logging

extension Logger {
    /// Strips `Bearer <token>` secrets from a string before it reaches the
    /// logs. Upstream error descriptions can embed the Authorization header;
    /// this guards against leaking the Hermes / provider key.
    static func redact(_ s: String) -> String {
        s.replacingOccurrences(
            of: #"Bearer\s+[A-Za-z0-9._\-]+"#,
            with: "Bearer ***",
            options: .regularExpression,
        )
    }
}

/// Times an async stage and logs `stage` + `duration_ms` on the given
/// (request-scoped) logger, carrying through any caller metadata. Success
/// logs at `.debug`; failure logs at `.error` with a redacted error string
/// and rethrows. The reusable convention for per-stage server observability.
@discardableResult
func loggedStage<T>(
    _ stage: String,
    logger: Logger,
    metadata: Logger.Metadata = [:],
    _ body: () async throws -> T,
) async throws -> T {
    let start = DispatchTime.now().uptimeNanoseconds
    func elapsedMs() -> Int64 {
        Int64((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    do {
        let result = try await body()
        var md = metadata
        md["stage"] = .string(stage)
        md["duration_ms"] = .stringConvertible(elapsedMs())
        logger.debug("stage ok", metadata: md)
        return result
    } catch {
        var md = metadata
        md["stage"] = .string(stage)
        md["duration_ms"] = .stringConvertible(elapsedMs())
        md["error"] = .string(Logger.redact(String(describing: error)))
        logger.error("stage failed", metadata: md)
        throw error
    }
}

struct DiscardingMetricsFactory: MetricsFactory {
    func makeCounter(label _: String, dimensions _: [(String, String)]) -> any CounterHandler {
        DiscardingCounter()
    }

    func makeMeter(label _: String, dimensions _: [(String, String)]) -> any MeterHandler {
        DiscardingMeter()
    }

    func makeRecorder(label _: String, dimensions _: [(String, String)], aggregate _: Bool) -> any RecorderHandler {
        DiscardingRecorder()
    }

    func makeTimer(label _: String, dimensions _: [(String, String)]) -> any TimerHandler {
        DiscardingTimer()
    }

    func destroyCounter(_: any CounterHandler) {}
    func destroyMeter(_: any MeterHandler) {}
    func destroyRecorder(_: any RecorderHandler) {}
    func destroyTimer(_: any TimerHandler) {}

    private final class DiscardingCounter: CounterHandler {
        func increment(by _: Int64) {}
        func reset() {}
    }

    private final class DiscardingMeter: MeterHandler {
        func set(_: Int64) {}
        func set(_: Double) {}
        func increment(by _: Double) {}
        func decrement(by _: Double) {}
    }

    private final class DiscardingRecorder: RecorderHandler {
        func record(_: Int64) {}
        func record(_: Double) {}
    }

    private final class DiscardingTimer: TimerHandler {
        func recordNanoseconds(_: Int64) {}
    }
}
