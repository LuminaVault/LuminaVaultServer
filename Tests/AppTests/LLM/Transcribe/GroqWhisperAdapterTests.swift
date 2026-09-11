@testable import App
import Foundation
import Testing

/// Unit tests for the Groq Whisper adapter's wire shaping.
///
/// The invariant these exist to protect: Groq and OpenAI select the audio
/// decoder from the *filename extension* in the multipart part, ignoring its
/// `Content-Type`. A body that is correctly typed but named `audio.bin` is
/// rejected upstream with a 400. So `TranscribeController.acceptedMimes` and
/// `GroqWhisperAdapter.filename(for:)` have to agree, and nothing enforces
/// that at compile time.
@Suite
struct GroqWhisperAdapterTests {
    // MARK: - Filename mapping

    /// The load-bearing test. Any mime the API layer accepts must map to a
    /// real extension — adding to `acceptedMimes` without adding to
    /// `filename(for:)` fails here rather than in production.
    @Test
    func everyAcceptedMimeMapsToARealExtension() {
        for mime in TranscribeController.acceptedMimes {
            let filename = GroqWhisperAdapter.filename(for: mime)
            #expect(
                filename != "audio.bin",
                "\(mime) is accepted by the API but has no filename mapping, so upstream will 400"
            )
            #expect(
                filename.contains("."),
                "\(mime) maps to \(filename), which has no extension for upstream to dispatch on"
            )
        }
    }

    /// Telegram voice notes are Opus-in-Ogg. This is the format the whole
    /// managed-voice path depends on, so it gets its own assertion.
    @Test
    func telegramVoiceNoteFormatsAreMapped() {
        #expect(GroqWhisperAdapter.filename(for: "audio/ogg") == "audio.ogg")
        #expect(GroqWhisperAdapter.filename(for: "audio/opus") == "audio.opus")
        #expect(TranscribeController.acceptedMimes.contains("audio/ogg"))
        #expect(TranscribeController.acceptedMimes.contains("audio/opus"))
    }

    @Test(arguments: [
        ("audio/m4a", "audio.m4a"),
        ("audio/x-m4a", "audio.m4a"),
        ("audio/mp4", "audio.mp4"),
        ("audio/wav", "audio.wav"),
        ("audio/x-wav", "audio.wav"),
        ("audio/mpeg", "audio.mp3"),
        ("audio/mpga", "audio.mpga"),
        ("audio/webm", "audio.webm"),
        ("audio/flac", "audio.flac"),
    ])
    func knownMimesMapToExpectedFilenames(mime: String, expected: String) {
        #expect(GroqWhisperAdapter.filename(for: mime) == expected)
    }

    /// The default stays reachable for genuinely unknown input — the function
    /// must remain total rather than trapping.
    @Test
    func unknownMimeFallsBackToBinary() {
        #expect(GroqWhisperAdapter.filename(for: "application/octet-stream") == "audio.bin")
        #expect(GroqWhisperAdapter.filename(for: "") == "audio.bin")
    }

    // MARK: - Multipart wire shape

    @Test
    func multipartBodyCarriesFilenameAndMimeForOgg() throws {
        let audio = Data([0x4F, 0x67, 0x67, 0x53]) // "OggS"
        let body = GroqWhisperAdapter.buildMultipartBody(
            boundary: "testboundary",
            audio: audio,
            filename: GroqWhisperAdapter.filename(for: "audio/ogg"),
            mime: "audio/ogg",
            model: "whisper-large-v3"
        )
        let text = try #require(String(data: body, encoding: .isoLatin1))

        #expect(text.contains("filename=\"audio.ogg\""))
        #expect(text.contains("Content-Type: audio/ogg"))
        #expect(text.contains("name=\"model\""))
        #expect(text.contains("whisper-large-v3"))
        #expect(text.contains("verbose_json"))
        #expect(text.hasSuffix("--testboundary--\r\n"))
    }

    /// The raw audio bytes must survive verbatim — no transcoding, no
    /// re-encoding. The server has no ffmpeg; it is a passthrough.
    @Test
    func multipartBodyPreservesAudioBytesVerbatim() {
        let audio = Data((0 ..< 256).map { UInt8($0) })
        let body = GroqWhisperAdapter.buildMultipartBody(
            boundary: "b",
            audio: audio,
            filename: "audio.ogg",
            mime: "audio/ogg",
            model: "m"
        )
        #expect(body.range(of: audio) != nil)
    }
}
