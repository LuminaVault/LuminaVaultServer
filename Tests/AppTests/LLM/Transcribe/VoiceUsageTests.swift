@testable import App
import Foundation
import Testing

/// Pure-function tests for the voice metering value types. No DB, no actor
/// I/O — channel sanitising, metric-label bounding and the imputed rate card
/// are all deterministic.
struct VoiceUsageTests {
    // MARK: - Channel sanitising

    /// The DB row keeps whatever the client claimed, reduced to a bare token.
    /// Unbounded is fine here: it is a JSONB value, not a metric dimension.
    @Test
    func `a plain platform name survives intact`() {
        #expect(VoiceChannel.sanitized("telegram") == "telegram")
        #expect(VoiceChannel.sanitized("whatsapp_cloud") == "whatsapp_cloud")
    }

    @Test
    func `case and surrounding whitespace are normalised away`() {
        #expect(VoiceChannel.sanitized("  Telegram  ") == "telegram")
    }

    /// A header value is attacker-controlled in the sense that any tenant
    /// container can set it. It reaches a SQL bind and a metric dimension, so
    /// it must be reduced to a token rather than trusted.
    @Test
    func `injection attempts truncate at the first invalid character`() {
        #expect(VoiceChannel.sanitized("telegram\nX-Evil: 1") == "telegram")
        #expect(VoiceChannel.sanitized("telegram'; DROP TABLE usage_events--") == "telegram")
    }

    @Test
    func `a missing or empty channel is unknown rather than nil`() {
        #expect(VoiceChannel.sanitized(nil) == VoiceChannel.unknown)
        #expect(VoiceChannel.sanitized("") == VoiceChannel.unknown)
        #expect(VoiceChannel.sanitized("   ") == VoiceChannel.unknown)
        #expect(VoiceChannel.sanitized("!!!") == VoiceChannel.unknown)
    }

    @Test
    func `an absurdly long value is capped`() {
        let long = String(repeating: "a", count: 500)
        #expect(VoiceChannel.sanitized(long).count == VoiceChannel.maxLength)
    }

    // MARK: - Metric labels

    /// Metric dimensions must stay bounded. A plugin platform names itself,
    /// and Prometheus charges for every distinct label value forever — one
    /// tenant sending a random channel per request would be a cardinality
    /// bomb that no amount of dashboard work recovers from.
    @Test
    func `known channels keep their own metric label`() {
        #expect(VoiceChannel.metricLabel(for: "telegram") == "telegram")
        #expect(VoiceChannel.metricLabel(for: "discord") == "discord")
        #expect(VoiceChannel.metricLabel(for: "app") == "app")
        #expect(VoiceChannel.metricLabel(for: VoiceChannel.unknown) == VoiceChannel.unknown)
    }

    @Test
    func `an unrecognised channel collapses to other in metrics`() {
        #expect(VoiceChannel.metricLabel(for: "somepluginplatform") == "other")
        // …while the DB row keeps the real name. That is the whole point of
        // having two functions.
        #expect(VoiceChannel.sanitized("somepluginplatform") == "somepluginplatform")
    }

    // MARK: - Imputed cost

    /// The cluster's whisper is free, so real spend is zero. The imputed rate
    /// answers the other question — what this traffic would have cost on a
    /// hosted provider — which is the number that justifies running our own.
    @Test
    func `imputed cost is the per-minute rate applied to the duration`() {
        // $0.006/minute — OpenAI's published whisper-1 rate.
        let card = TranscribeRateCard(imputedUsdPerAudioMinute: 0.006)
        // 60s = 1 minute = $0.006 = 6_000 micro-USD.
        #expect(card.imputedUsdMicros(durationSeconds: 60) == 6000)
        // 30s = half that.
        #expect(card.imputedUsdMicros(durationSeconds: 30) == 3000)
    }

    @Test
    func `a zero rate imputes nothing`() {
        let card = TranscribeRateCard(imputedUsdPerAudioMinute: 0)
        #expect(card.imputedUsdMicros(durationSeconds: 600) == 0)
    }

    /// Duration arrives from an upstream JSON body. A provider that omits it
    /// or reports nonsense must not produce negative money.
    @Test
    func `negative or non-finite durations clamp to zero`() {
        let card = TranscribeRateCard(imputedUsdPerAudioMinute: 0.006)
        #expect(card.imputedUsdMicros(durationSeconds: -10) == 0)
        #expect(card.imputedUsdMicros(durationSeconds: .nan) == 0)
        #expect(card.imputedUsdMicros(durationSeconds: .infinity) == 0)
    }

    // MARK: - Outcome mapping

    /// Outcome is the reason the row exists: a failure rate is invisible if
    /// only successes are recorded.
    @Test
    func `each upstream error maps to its own outcome`() {
        #expect(
            VoiceUsageOutcome(
                providerError: .permanent(provider: .stub, status: 400, body: nil)
            ) == .upstreamPermanent
        )
        #expect(
            VoiceUsageOutcome(
                providerError: .transient(provider: .stub, status: 503, body: nil)
            ) == .upstreamTransient
        )
        #expect(
            VoiceUsageOutcome(
                providerError: .network(provider: .stub, underlying: URLError(.timedOut))
            ) == .network
        )
        #expect(
            VoiceUsageOutcome(
                providerError: .decode(provider: .stub, underlying: URLError(.cannotParseResponse))
            ) == .decode
        )
    }

    /// Outcomes are written to a JSONB column and read back by dashboard
    /// queries. Renaming one silently breaks every saved query, so the wire
    /// strings are pinned here.
    @Test
    func `outcome wire values are stable`() {
        #expect(VoiceUsageOutcome.ok.rawValue == "ok")
        #expect(VoiceUsageOutcome.upstreamPermanent.rawValue == "upstream_permanent")
        #expect(VoiceUsageOutcome.upstreamTransient.rawValue == "upstream_transient")
        #expect(VoiceUsageOutcome.network.rawValue == "network")
        #expect(VoiceUsageOutcome.decode.rawValue == "decode")
        #expect(VoiceUsageOutcome.noProvider.rawValue == "no_provider")
    }
}
