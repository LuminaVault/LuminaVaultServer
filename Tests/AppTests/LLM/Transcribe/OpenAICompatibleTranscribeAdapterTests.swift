@testable import App
import Foundation
import Testing

/// Unit tests for the OpenAI-compatible transcription adapter's wire shaping.
///
/// The invariant these exist to protect: Whisper-family endpoints select the audio
/// decoder from the *filename extension* in the multipart part, ignoring its
/// `Content-Type`. A body that is correctly typed but named `audio.bin` is
/// rejected upstream with a 400. So `TranscribeController.acceptedMimes` and
/// `OpenAICompatibleTranscribeAdapter.filename(for:)` have to agree, and nothing enforces
/// that at compile time.
struct OpenAICompatibleTranscribeAdapterTests {
    // MARK: - Filename mapping

    /// The load-bearing test. Any mime the API layer accepts must map to a
    /// real extension — adding to `acceptedMimes` without adding to
    /// `filename(for:)` fails here rather than in production.
    @Test
    func everyAcceptedMimeMapsToARealExtension() {
        for mime in TranscribeController.acceptedMimes {
            let filename = OpenAICompatibleTranscribeAdapter.filename(for: mime)
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
        #expect(OpenAICompatibleTranscribeAdapter.filename(for: "audio/ogg") == "audio.ogg")
        #expect(OpenAICompatibleTranscribeAdapter.filename(for: "audio/opus") == "audio.opus")
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
        #expect(OpenAICompatibleTranscribeAdapter.filename(for: mime) == expected)
    }

    /// The default stays reachable for genuinely unknown input — the function
    /// must remain total rather than trapping.
    @Test
    func unknownMimeFallsBackToBinary() {
        #expect(OpenAICompatibleTranscribeAdapter.filename(for: "application/octet-stream") == "audio.bin")
        #expect(OpenAICompatibleTranscribeAdapter.filename(for: "") == "audio.bin")
    }

    // MARK: - Endpoint shaping

    /// `baseURL` carries the version prefix, so the adapter appends only the
    /// endpoint path. The previous Groq-specific version appended
    /// `/openai/v1` itself, which against a base that already ends in `/v1`
    /// produces `/v1/openai/v1/audio/transcriptions` and a 404.
    @Test(arguments: [
        ("http://whisper.horus.svc.cluster.local:8000/v1",
         "http://whisper.horus.svc.cluster.local:8000/v1/audio/transcriptions"),
        ("https://api.openai.com/v1", "https://api.openai.com/v1/audio/transcriptions"),
        // A vendor whose version prefix is not at the root carries it in the
        // configured value rather than in our code.
        ("https://api.groq.com/openai/v1", "https://api.groq.com/openai/v1/audio/transcriptions"),
    ])
    func appendsOnlyTheEndpointPathToTheConfiguredBase(base: String, expected: String) throws {
        let url = try #require(URL(string: base))
            .appendingPathComponent("audio")
            .appendingPathComponent("transcriptions")
        #expect(url.absoluteString == expected)
    }

    // MARK: - Multipart wire shape

    @Test
    func multipartBodyCarriesFilenameAndMimeForOgg() throws {
        let audio = Data([0x4F, 0x67, 0x67, 0x53]) // "OggS"
        let body = OpenAICompatibleTranscribeAdapter.buildMultipartBody(
            boundary: "testboundary",
            audio: audio,
            filename: OpenAICompatibleTranscribeAdapter.filename(for: "audio/ogg"),
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
        let body = OpenAICompatibleTranscribeAdapter.buildMultipartBody(
            boundary: "b",
            audio: audio,
            filename: "audio.ogg",
            mime: "audio/ogg",
            model: "m"
        )
        #expect(body.range(of: audio) != nil)
    }
}
