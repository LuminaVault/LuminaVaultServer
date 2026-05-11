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
