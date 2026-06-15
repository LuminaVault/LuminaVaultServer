@testable import App
import CoreMetrics
import Foundation
import Metrics
import Testing

@Suite(.serialized, .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct UpstreamErrorTelemetryTests {
    final class StubMetricsFactory: MetricsFactory, @unchecked Sendable {
        nonisolated(unsafe) var counterIncrements: [(label: String, dimensions: [(String, String)], by: Int64)] = []

        func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
            let factory = self
            return StubCounter(label: label, dimensions: dimensions, factory: factory)
        }

        func makeRecorder(label _: String, dimensions _: [(String, String)], aggregate _: Bool) -> RecorderHandler {
            StubRecorder()
        }

        func makeTimer(label _: String, dimensions _: [(String, String)]) -> TimerHandler {
            StubTimer()
        }

        func makeMeter(label _: String, dimensions _: [(String, String)]) -> MeterHandler {
            StubMeter()
        }

        func destroyCounter(_: CounterHandler) {}
        func destroyRecorder(_: RecorderHandler) {}
        func destroyTimer(_: TimerHandler) {}
        func destroyMeter(_: MeterHandler) {}
    }

    final class StubCounter: CounterHandler, @unchecked Sendable {
        let label: String
        let dimensions: [(String, String)]
        let factory: StubMetricsFactory
        init(label: String, dimensions: [(String, String)], factory: StubMetricsFactory) {
            self.label = label
            self.dimensions = dimensions
            self.factory = factory
        }

        func increment(by: Int64) {
            factory.counterIncrements.append((label, dimensions, by))
        }

        func reset() {}
    }

    final class StubRecorder: RecorderHandler, @unchecked Sendable {
        func record(_: Int64) {}
        func record(_: Double) {}
    }

    final class StubTimer: TimerHandler, @unchecked Sendable {
        func recordNanoseconds(_: Int64) {}
    }

    final class StubMeter: MeterHandler, @unchecked Sendable {
        func set(_: Int64) {}
        func set(_: Double) {}
        func increment(by _: Double) {}
        func decrement(by _: Double) {}
    }

    @Test
    func `record increments counter with reason_code dimension`() {
        let factory = StubMetricsFactory()

        UpstreamErrorTelemetry.record(reasonCode: "upstream_timeout", provider: "hermesGateway", factory: factory)
        UpstreamErrorTelemetry.record(reasonCode: "upstream_unreachable", provider: "hermesGateway", factory: factory)

        #expect(factory.counterIncrements.count == 2)
        #expect(factory.counterIncrements[0].label == "luminavault.llm.chat.upstream_error")
        #expect(factory.counterIncrements[0].dimensions.contains(where: { $0.0 == "code" && $0.1 == "upstream_timeout" }))
        #expect(factory.counterIncrements[0].dimensions.contains(where: { $0.0 == "provider" && $0.1 == "hermesGateway" }))
        #expect(factory.counterIncrements[1].dimensions.contains(where: { $0.0 == "code" && $0.1 == "upstream_unreachable" }))
    }
}
