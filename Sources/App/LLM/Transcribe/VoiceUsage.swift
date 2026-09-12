import Foundation

/// Where a transcription request came from.
///
/// Over the OpenAI wire shape the server can only see the tenant — a Telegram
/// voice note and an iOS mic recording arrive identical. Hermes names the
/// origin in `X-Lumina-Channel`; this reduces whatever it claimed to something
/// safe to store and to graph.
///
/// Two functions rather than one on purpose:
/// - `sanitized` keeps the real name for the usage row, which is JSONB and
///   does not care how many distinct values exist.
/// - `metricLabel` collapses anything unrecognised to `other`, because a
///   metric dimension does care: a plugin platform names itself, and one
///   tenant sending a fresh channel per request would be a cardinality bomb
///   that no amount of dashboard work recovers from.
enum VoiceChannel {
    /// Recorded when the header is absent, empty, or entirely unusable.
    /// A string rather than `nil` so "we don't know" is a value you can
    /// `GROUP BY` instead of a hole in the data.
    static let unknown = "unknown"

    /// Long enough for every real platform name, short enough that a hostile
    /// value cannot bloat a row or a label.
    static let maxLength = 32

    /// Channels that get their own metric dimension. Everything else is
    /// `other` — still counted, just not separately.
    static let knownMetricLabels: Set<String> = [
        "app",
        "telegram",
        "discord",
        "whatsapp",
        "whatsapp_cloud",
        "slack",
        "signal",
        "bluebubbles",
        "cli",
        unknown,
    ]

    /// Reduce a claimed channel to a bare lowercase token.
    ///
    /// Truncates at the first character outside `[a-z0-9_-]` rather than
    /// filtering those characters out: `"telegram\nX-Evil: 1"` must become
    /// `"telegram"`, not `"telegramxevil1"`. A filter would splice injected
    /// text onto a legitimate name and yield a plausible-looking channel that
    /// no platform actually is. Mirrors `_normalize_channel` on the Hermes
    /// side, which scrubs the same value before it reaches the wire — both
    /// ends scrub because either end can be the one talking to something
    /// unexpected.
    static func sanitized(_ raw: String?) -> String {
        guard let raw else { return unknown }
        var token = ""
        for character in raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            guard character.isASCII,
                  character.isLetter || character.isNumber || character == "_" || character == "-"
            else { break }
            token.append(character)
            if token.count == maxLength {
                break
            }
        }
        return token.isEmpty ? unknown : token
    }

    /// Bounded dimension value for metrics.
    static func metricLabel(for channel: String) -> String {
        knownMetricLabels.contains(channel) ? channel : "other"
    }
}

/// How a transcription attempt ended.
///
/// Recorded on every attempt, not only successes: metering only what worked
/// makes a failing provider look like a drop in demand, so the dashboard goes
/// quiet exactly when something is wrong.
///
/// Raw values are written into a JSONB column and read back by saved
/// dashboard queries. Renaming one silently breaks every one of them, so
/// `VoiceUsageTests` pins the strings.
enum VoiceUsageOutcome: String, Sendable, Equatable {
    case ok
    case upstreamPermanent = "upstream_permanent"
    case upstreamTransient = "upstream_transient"
    case network
    case decode
    /// No provider configured — the request never reached an adapter. The
    /// failure mode most worth seeing on a dashboard, since it means a
    /// deployment is misconfigured rather than an upstream being flaky.
    case noProvider = "no_provider"
}

extension VoiceUsageOutcome {
    init(providerError: TranscribeProviderError) {
        switch providerError {
        case .permanent: self = .upstreamPermanent
        case .transient: self = .upstreamTransient
        case .network: self = .network
        case .decode: self = .decode
        }
    }
}

/// One transcription attempt, as metered.
///
/// Durations are milliseconds and money is micro-USD — both integers, because
/// the columns they land in are integers and float drift in a money column is
/// a bug you find months later in a reconciliation.
struct VoiceUsageEvent: Sendable, Equatable {
    let tenantID: UUID
    let occurredAt: Date
    let channel: String
    let surface: String
    let provider: String
    let model: String
    let outcome: VoiceUsageOutcome
    let durationMilliseconds: Int64
    let latencyMilliseconds: Int64
    let audioBytes: Int64
    let language: String?
    /// Real spend. Zero for the in-cluster whisper service, which bills
    /// nothing — see `TranscribeRateCard`.
    let usdMicros: Int64
    /// What this would have cost on a hosted provider at the configured
    /// shadow rate. Never booked to `cost_ledger`; it is not money anyone
    /// owes, only the number that says what running our own whisper saves.
    let imputedUsdMicros: Int64
    /// Dedupe key for the usage-events unique index. The response id, so a
    /// retried write cannot double-count.
    let idempotencyKey: String

    /// Default surface for inbound voice notes. Spoken *replies* will be a
    /// second surface once `/v1/audio/speech` stops returning 501.
    static let voiceNoteSurface = "voice_note"
}

/// Sink for `VoiceUsageEvent`s. A protocol so `TranscribeService` can be
/// tested without a database, and so the store's failure handling stays its
/// own business.
protocol VoiceUsageRecorder: Sendable {
    func record(_ event: VoiceUsageEvent) async
}

/// Per-provider pricing for transcription.
///
/// The cluster's whisper is free per request, so real spend is genuinely
/// zero. The imputed rate answers the other question — what this traffic
/// would have cost hosted — which is what makes "running our own saves $X"
/// a measured claim rather than an assertion.
struct TranscribeRateCard: Sendable, Equatable {
    /// USD per minute of audio at the provider's published rate. Zero means
    /// "don't impute", which is the default: inventing a rate nobody
    /// configured would be worse than having no number.
    let imputedUsdPerAudioMinute: Double

    func imputedUsdMicros(durationSeconds: Double) -> Int64 {
        guard imputedUsdPerAudioMinute > 0,
              durationSeconds.isFinite,
              durationSeconds > 0
        else { return 0 }
        let usd = (durationSeconds / 60.0) * imputedUsdPerAudioMinute
        let micros = (usd * 1_000_000).rounded()
        guard micros.isFinite, micros > 0 else { return 0 }
        return Int64(min(micros, Double(Int64.max)))
    }
}
