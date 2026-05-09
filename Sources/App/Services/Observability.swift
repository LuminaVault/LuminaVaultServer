import Foundation
import Logging
import Metrics
import Tracing

struct RouteTelemetry: Sendable {
    let logger: Logger
    let requestCounter: Counter
    let failureCounter: Counter
    let durationTimer: Timer

    init(labelPrefix: String, logger: Logger) {
        self.logger = logger
        self.requestCounter = Counter(label: "luminavault.\(labelPrefix).requests")
        self.failureCounter = Counter(label: "luminavault.\(labelPrefix).failures")
        self.durationTimer = Timer(label: "luminavault.\(labelPrefix).duration")
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
    func makeCounter(label: String, dimensions: [(String, String)]) -> any CounterHandler { DiscardingCounter() }
    func makeMeter(label: String, dimensions: [(String, String)]) -> any MeterHandler { DiscardingMeter() }
    func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> any RecorderHandler { DiscardingRecorder() }
    func makeTimer(label: String, dimensions: [(String, String)]) -> any TimerHandler { DiscardingTimer() }

    func destroyCounter(_ handler: any CounterHandler) {}
    func destroyMeter(_ handler: any MeterHandler) {}
    func destroyRecorder(_ handler: any RecorderHandler) {}
    func destroyTimer(_ handler: any TimerHandler) {}

    private final class DiscardingCounter: CounterHandler {
        func increment(by amount: Int64) {}
        func reset() {}
    }

    private final class DiscardingMeter: MeterHandler {
        func set(_ value: Int64) {}
        func set(_ value: Double) {}
        func increment(by value: Double) {}
        func decrement(by value: Double) {}
    }

    private final class DiscardingRecorder: RecorderHandler {
        func record(_ value: Int64) {}
        func record(_ value: Double) {}
    }

    private final class DiscardingTimer: TimerHandler {
        func recordNanoseconds(_ duration: Int64) {}
    }
}