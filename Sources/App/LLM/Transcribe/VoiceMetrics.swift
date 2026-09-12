import Foundation
import Metrics

/// Live voice-path signals, exported when `otel.enabled=true` and discarded
/// into `DiscardingMetricsFactory` otherwise — so this costs nothing on a
/// deployment that has not turned observability on.
///
/// Deliberately parallel to, not a replacement for, the `usage_events` rows.
/// Metrics answer "is voice healthy right now" with alerting latency; the
/// rows answer "what did this tenant actually use" with exact, durable
/// numbers. Neither substitutes for the other: a sampled histogram is not a
/// billing record, and a SQL aggregate is not an alert.
enum VoiceMetrics {
    /// Every attempt, dimensioned by where it came from and how it ended.
    /// The failure rate is `outcome != "ok"` over this — which only works
    /// because failures are counted too.
    static func recordTranscribe(_ event: VoiceUsageEvent) {
        let dimensions = Self.dimensions(for: event)
        Counter(label: "luminavault.voice.transcribe.requests", dimensions: dimensions).increment()

        // Only successful attempts carry a real duration; counting the zero
        // from a failure would drag the median toward nothing and hide a
        // change in what users are actually sending.
        guard event.outcome == .ok else { return }

        Timer(
            label: "luminavault.voice.transcribe.audio_duration",
            dimensions: dimensions + [("unit", "s")]
        ).recordNanoseconds(event.durationMilliseconds * 1_000_000)

        Timer(
            label: "luminavault.voice.transcribe.latency",
            dimensions: dimensions + [("unit", "s")]
        ).recordNanoseconds(event.latencyMilliseconds * 1_000_000)

        Recorder(
            label: "luminavault.voice.transcribe.audio_bytes",
            dimensions: dimensions
        ).record(event.audioBytes)
    }

    /// Bounded dimensions.
    ///
    /// `channel` goes through `VoiceChannel.metricLabel`, and tenant id is
    /// deliberately absent: per-tenant series would multiply every instrument
    /// by the user count, and that question belongs to the `usage_events`
    /// rows, which cost nothing extra to keep.
    static func dimensions(for event: VoiceUsageEvent) -> [(String, String)] {
        [
            ("provider", event.provider),
            ("channel", VoiceChannel.metricLabel(for: event.channel)),
            ("outcome", event.outcome.rawValue),
        ]
    }
}
