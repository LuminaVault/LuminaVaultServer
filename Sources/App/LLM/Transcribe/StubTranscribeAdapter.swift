import Foundation
import LuminaVaultShared
import NIOCore

/// HER-203 — test-only adapter that returns a deterministic
/// `TranscribeUpstreamResult` without touching any network. Wired by
/// `App+build` ONLY when `transcribe.provider=stub`; production deploys
/// leave the active provider as `groq` (or other) and never reach this
/// branch. The values are read from config so each test suite can pin
/// its own fixture without rebuilding the adapter.
struct StubTranscribeAdapter: TranscribeProviderAdapter {
    let kind: TranscribeProviderKind = .stub
    let text: String
    let language: String
    let confidence: Double
    let durationSeconds: Double
    let segments: [TranscribeSegment]?

    init(
        text: String = "stub transcript",
        language: String = "en",
        confidence: Double = 0.95,
        durationSeconds: Double = 30,
        segments: [TranscribeSegment]? = nil,
    ) {
        self.text = text
        self.language = language
        self.confidence = confidence
        self.durationSeconds = durationSeconds
        self.segments = segments
    }

    func transcribe(audio _: ByteBuffer, mime _: String) async throws -> TranscribeUpstreamResult {
        TranscribeUpstreamResult(
            text: text,
            language: language,
            confidence: confidence,
            durationSeconds: durationSeconds,
            segments: segments ?? [TranscribeSegment(start: 0, end: durationSeconds, text: text)],
        )
    }
}
