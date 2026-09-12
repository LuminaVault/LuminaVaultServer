@testable import App
import Foundation
import Hummingbird
import Logging
import NIOCore
import Testing

/// What `TranscribeService` records, and when.
///
/// The invariant: **every** transcription attempt leaves exactly one usage
/// event, success or not. Metering only the successes makes a failing
/// provider look like a drop in demand — the dashboard goes quiet precisely
/// when something is wrong, which is the opposite of what it is for.
struct TranscribeServiceUsageTests {
    // MARK: - Doubles

    /// Collects events instead of writing them. An actor because
    /// `VoiceUsageRecorder` is `Sendable` and the events have to be read back
    /// safely from the test body.
    actor RecordingVoiceUsage: VoiceUsageRecorder {
        private(set) var events: [VoiceUsageEvent] = []

        func record(_ event: VoiceUsageEvent) async {
            events.append(event)
        }
    }

    /// How the stub should fail.
    ///
    /// A descriptor rather than a stored `TranscribeProviderError`: that enum
    /// carries `any Error` in two of its cases, so it is not `Sendable`, and
    /// `TranscribeProviderAdapter` requires conformers to be.
    enum StubFailure: Sendable {
        case permanent
        case transient
        case network
        case decode

        var error: TranscribeProviderError {
            switch self {
            case .permanent: .permanent(provider: .stub, status: 400, body: "nope")
            case .transient: .transient(provider: .stub, status: 503, body: nil)
            case .network: .network(provider: .stub, underlying: URLError(.timedOut))
            case .decode: .decode(provider: .stub, underlying: URLError(.cannotParseResponse))
            }
        }
    }

    struct StubAdapter: TranscribeProviderAdapter {
        let kind: TranscribeProviderKind = .stub
        var success: TranscribeUpstreamResult?
        var failure: StubFailure?

        func transcribe(audio _: ByteBuffer, mime _: String) async throws -> TranscribeUpstreamResult {
            if let failure {
                throw failure.error
            }
            return success ?? TranscribeServiceUsageTests.upstreamResult()
        }
    }

    static func upstreamResult(durationSeconds: Double = 12) -> TranscribeUpstreamResult {
        TranscribeUpstreamResult(
            text: "hello",
            language: "en",
            confidence: 0.9,
            durationSeconds: durationSeconds,
            segments: nil
        )
    }

    static func makeService(
        adapter: any TranscribeProviderAdapter,
        recorder: any VoiceUsageRecorder,
        imputedUsdPerAudioMinute: Double = 0.006
    ) -> TranscribeService {
        let logger = Logger(label: "test")
        let registry = TranscribeProviderRegistry(
            active: .stub,
            configs: [
                TranscribeProviderConfig(
                    kind: .stub,
                    apiKey: "k",
                    baseURL: nil,
                    model: "stub",
                    mtokPerSecond: 0,
                    imputedUsdPerAudioMinute: imputedUsdPerAudioMinute
                ),
            ],
            adapters: [adapter],
            logger: logger
        )
        return TranscribeService(
            registry: registry,
            usageMeter: nil,
            voiceUsage: recorder,
            logger: logger
        )
    }

    static func audio() -> ByteBuffer {
        ByteBuffer(bytes: [0x01, 0x02, 0x03, 0x04])
    }

    // MARK: - Success

    @Test
    func `a successful transcription records one event`() async throws {
        let recorder = RecordingVoiceUsage()
        let service = Self.makeService(
            adapter: StubAdapter(success: Self.upstreamResult(durationSeconds: 12)),
            recorder: recorder
        )

        _ = try await service.transcribe(
            audio: Self.audio(),
            mime: "audio/ogg",
            tenantID: UUID(),
            channel: "telegram"
        )

        let events = await recorder.events
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.outcome == .ok)
        #expect(event.channel == "telegram")
        #expect(event.durationMilliseconds == 12000)
        #expect(event.provider == "stub")
    }

    /// Duration is the billable quantity. It is stored in milliseconds
    /// because the column is an integer and a 900ms voice note rounding to
    /// zero seconds would meter as free.
    @Test
    func `sub-second audio still records a non-zero duration`() async throws {
        let recorder = RecordingVoiceUsage()
        let service = Self.makeService(
            adapter: StubAdapter(success: Self.upstreamResult(durationSeconds: 0.9)),
            recorder: recorder
        )

        _ = try await service.transcribe(
            audio: Self.audio(), mime: "audio/ogg", tenantID: UUID(), channel: "telegram"
        )

        let event = try #require(await recorder.events.first)
        #expect(event.durationMilliseconds == 900)
    }

    @Test
    func `the imputed cost rides on the event`() async throws {
        let recorder = RecordingVoiceUsage()
        let service = Self.makeService(
            adapter: StubAdapter(success: Self.upstreamResult(durationSeconds: 60)),
            recorder: recorder,
            imputedUsdPerAudioMinute: 0.006
        )

        _ = try await service.transcribe(
            audio: Self.audio(), mime: "audio/ogg", tenantID: UUID(), channel: "telegram"
        )

        let event = try #require(await recorder.events.first)
        #expect(event.imputedUsdMicros == 6000)
        // Real spend stays zero: the in-cluster service bills nothing, and
        // booking imputed money as real would corrupt the cost ledger.
        #expect(event.usdMicros == 0)
    }

    @Test
    func `an absent channel header is recorded as unknown`() async throws {
        let recorder = RecordingVoiceUsage()
        let service = Self.makeService(
            adapter: StubAdapter(success: Self.upstreamResult()),
            recorder: recorder
        )

        _ = try await service.transcribe(
            audio: Self.audio(), mime: "audio/ogg", tenantID: UUID(), channel: nil
        )

        let event = try #require(await recorder.events.first)
        #expect(event.channel == VoiceChannel.unknown)
    }

    // MARK: - Failure

    @Test
    func `an upstream failure records an event and still throws`() async throws {
        let recorder = RecordingVoiceUsage()
        let service = Self.makeService(
            adapter: StubAdapter(failure: .permanent),
            recorder: recorder
        )

        await #expect(throws: HTTPError.self) {
            _ = try await service.transcribe(
                audio: Self.audio(), mime: "audio/ogg", tenantID: UUID(), channel: "telegram"
            )
        }

        let events = await recorder.events
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.outcome == .upstreamPermanent)
        #expect(event.channel == "telegram")
        // Nothing was transcribed, so there is no duration to bill — but the
        // attempt is still on the record.
        #expect(event.durationMilliseconds == 0)
        #expect(event.imputedUsdMicros == 0)
    }

    @Test
    func `a transient failure is distinguishable from a permanent one`() async throws {
        let recorder = RecordingVoiceUsage()
        let service = Self.makeService(
            adapter: StubAdapter(failure: .transient),
            recorder: recorder
        )

        await #expect(throws: HTTPError.self) {
            _ = try await service.transcribe(
                audio: Self.audio(), mime: "audio/ogg", tenantID: UUID(), channel: "telegram"
            )
        }

        let event = try #require(await recorder.events.first)
        #expect(event.outcome == .upstreamTransient)
    }

    /// A misconfigured deployment is the failure mode most worth seeing on a
    /// dashboard, and it never reaches an adapter at all.
    @Test
    func `no configured provider records a no_provider event`() async throws {
        let recorder = RecordingVoiceUsage()
        let logger = Logger(label: "test")
        let registry = TranscribeProviderRegistry(
            active: .stub, configs: [], adapters: [], logger: logger
        )
        let service = TranscribeService(
            registry: registry, usageMeter: nil, voiceUsage: recorder, logger: logger
        )

        await #expect(throws: HTTPError.self) {
            _ = try await service.transcribe(
                audio: Self.audio(), mime: "audio/ogg", tenantID: UUID(), channel: "telegram"
            )
        }

        let event = try #require(await recorder.events.first)
        #expect(event.outcome == .noProvider)
    }

    // MARK: - Metering must never break transcription

    /// The recorder writes to Postgres. A metering blip must cost a row, not
    /// the user's voice note.
    ///
    /// `VoiceUsageRecorder.record` cannot throw — that is the design, and
    /// this pins it: a recorder that does nothing at all still yields a
    /// complete response, so no future change can make transcription depend
    /// on metering having worked.
    @Test
    func `a recorder that does nothing still yields a full response`() async throws {
        struct SilentRecorder: VoiceUsageRecorder {
            func record(_: VoiceUsageEvent) async {}
        }

        let service = Self.makeService(
            adapter: StubAdapter(success: Self.upstreamResult()),
            recorder: SilentRecorder()
        )

        let response = try await service.transcribe(
            audio: Self.audio(), mime: "audio/ogg", tenantID: UUID(), channel: "telegram"
        )
        #expect(response.text == "hello")
    }
}
