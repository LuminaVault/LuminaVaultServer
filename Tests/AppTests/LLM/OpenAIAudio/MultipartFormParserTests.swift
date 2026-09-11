@testable import App
import Foundation
import NIOCore
import Testing

/// Unit tests for the hand-rolled multipart reader.
///
/// The fixture in `realHTTPXBody` is a verbatim capture of what httpx (and
/// therefore the OpenAI Python SDK) puts on the wire for a transcription
/// call. Its file payload deliberately embeds `\r\n--notaboundary` — the
/// shape that truncates a parser which searches for the delimiter alone
/// instead of CRLF-then-delimiter.
@Suite
struct MultipartFormParserTests {
    static let realBoundary = "957a64b387861839220bf7620e771fe7"

    /// Captured from `httpx.Request(..., data=..., files=...)`.
    static let realHTTPXBody: [UInt8] = {
        let head = "--\(realBoundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"
            + "--\(realBoundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\ntext\r\n"
            + "--\(realBoundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.ogg\"\r\n"
            + "Content-Type: audio/ogg\r\n\r\n"
        let tail = "\r\n--\(realBoundary)--\r\n"
        return Array(head.utf8) + audioPayload + Array(tail.utf8)
    }()

    /// "OggS" magic, two binary bytes, then a decoy boundary-looking run.
    static let audioPayload: [UInt8] =
        Array("OggS".utf8) + [0x00, 0x02] + Array("BINARY\r\n--notaboundary".utf8)

    // MARK: - Boundary extraction

    @Test
    func extractsUnquotedBoundary() {
        let header = "multipart/form-data; boundary=\(Self.realBoundary)"
        #expect(MultipartFormParser.boundary(fromContentType: header) == Self.realBoundary)
    }

    @Test
    func extractsQuotedBoundary() {
        #expect(MultipartFormParser.boundary(fromContentType: "multipart/form-data; boundary=\"abc\"") == "abc")
    }

    @Test
    func boundaryParameterNameIsCaseInsensitive() {
        #expect(MultipartFormParser.boundary(fromContentType: "multipart/form-data; BOUNDARY=xy") == "xy")
    }

    @Test
    func returnsNilWhenNoBoundaryPresent() {
        #expect(MultipartFormParser.boundary(fromContentType: "application/json") == nil)
        #expect(MultipartFormParser.boundary(fromContentType: "multipart/form-data") == nil)
        #expect(MultipartFormParser.boundary(fromContentType: "multipart/form-data; boundary=") == nil)
    }

    // MARK: - Parsing a real body

    @Test
    func parsesRealHTTPXBody() throws {
        let parts = try MultipartFormParser.parse(
            ByteBuffer(bytes: Self.realHTTPXBody),
            boundary: Self.realBoundary
        )

        #expect(parts.count == 3)
        #expect(parts.map(\.name) == ["model", "response_format", "file"])
        #expect(String(buffer: parts[0].body) == "whisper-1")
        #expect(String(buffer: parts[1].body) == "text")
        #expect(parts[2].filename == "audio.ogg")
        #expect(parts[2].contentType == "audio/ogg")
        // Data fields carry no filename — this is how the controller tells a
        // file part from a form field.
        #expect(parts[0].filename == nil)
    }

    /// The regression this parser shape exists for.
    @Test
    func binaryPayloadContainingBoundaryLikeBytesSurvivesVerbatim() throws {
        let parts = try MultipartFormParser.parse(
            ByteBuffer(bytes: Self.realHTTPXBody),
            boundary: Self.realBoundary
        )
        let file = try #require(parts.first { $0.name == "file" })
        #expect(Array(file.body.readableBytesView) == Self.audioPayload)
    }

    /// Round-trip against the writer we already ship, so the two stay honest
    /// about the same format.
    @Test
    func roundTripsBodyProducedByGroqWhisperAdapter() throws {
        let audio = Data((0 ..< 512).map { UInt8($0 % 256) })
        let boundary = "roundtripboundary"
        let written = GroqWhisperAdapter.buildMultipartBody(
            boundary: boundary,
            audio: audio,
            filename: "audio.ogg",
            mime: "audio/ogg",
            model: "whisper-large-v3"
        )

        let parts = try MultipartFormParser.parse(ByteBuffer(bytes: written), boundary: boundary)

        #expect(Set(parts.map(\.name)) == ["file", "model", "response_format", "temperature"])
        let file = try #require(parts.first { $0.name == "file" })
        #expect(file.filename == "audio.ogg")
        #expect(file.contentType == "audio/ogg")
        #expect(Data(file.body.readableBytesView) == audio)
    }

    // MARK: - Shape edge cases

    @Test
    func parsesPartWithEmptyBodyAndNoContentType() throws {
        let raw = "--zz\r\nContent-Disposition: form-data; name=\"empty\"\r\n\r\n\r\n--zz--\r\n"
        let parts = try MultipartFormParser.parse(ByteBuffer(string: raw), boundary: "zz")

        #expect(parts.count == 1)
        #expect(parts[0].body.readableBytes == 0)
        #expect(parts[0].contentType == nil)
    }

    @Test
    func skipsPreambleBeforeFirstDelimiter() throws {
        let raw = "ignored preamble\r\n--zz\r\nContent-Disposition: form-data; name=\"n\"\r\n\r\nv\r\n--zz--\r\n"
        let parts = try MultipartFormParser.parse(ByteBuffer(string: raw), boundary: "zz")

        #expect(parts.count == 1)
        #expect(parts[0].name == "n")
    }

    @Test
    func ignoresEpilogueAfterClosingDelimiter() throws {
        let raw = "--zz\r\nContent-Disposition: form-data; name=\"n\"\r\n\r\nv\r\n--zz--\r\ntrailing junk"
        let parts = try MultipartFormParser.parse(ByteBuffer(string: raw), boundary: "zz")

        #expect(parts.count == 1)
    }

    // MARK: - Failure modes

    @Test
    func throwsWhenBodyIsNotMultipart() {
        #expect(throws: MultipartFormParser.ParseError.noOpeningDelimiter) {
            try MultipartFormParser.parse(ByteBuffer(string: "hello"), boundary: "zzz")
        }
    }

    @Test
    func throwsWhenBodyIsTruncated() {
        let truncated = Array(Self.realHTTPXBody.prefix(180))
        #expect(throws: (any Error).self) {
            try MultipartFormParser.parse(ByteBuffer(bytes: truncated), boundary: Self.realBoundary)
        }
    }

    @Test
    func throwsWhenClosingDelimiterIsMissing() {
        let raw = "--zz\r\nContent-Disposition: form-data; name=\"n\"\r\n\r\nvalue"
        #expect(throws: MultipartFormParser.ParseError.unterminated) {
            try MultipartFormParser.parse(ByteBuffer(string: raw), boundary: "zz")
        }
    }

    @Test
    func throwsWhenPartHasNoName() {
        let raw = "--zz\r\nContent-Disposition: form-data\r\n\r\nv\r\n--zz--\r\n"
        #expect(throws: MultipartFormParser.ParseError.malformedPart) {
            try MultipartFormParser.parse(ByteBuffer(string: raw), boundary: "zz")
        }
    }

    @Test
    func throwsWhenPartCountExceedsLimit() {
        var raw = ""
        for i in 0 ..< 5 {
            raw += "--zz\r\nContent-Disposition: form-data; name=\"n\(i)\"\r\n\r\nv\r\n"
        }
        raw += "--zz--\r\n"

        #expect(throws: MultipartFormParser.ParseError.tooManyParts) {
            try MultipartFormParser.parse(ByteBuffer(string: raw), boundary: "zz", maxParts: 3)
        }
    }
}
