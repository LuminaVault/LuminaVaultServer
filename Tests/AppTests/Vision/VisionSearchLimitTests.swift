@testable import App
import Foundation
import Hummingbird
import Testing

/// The request parsing on `POST /v1/vision/search`.
///
/// `limit` bounds a vector scan whose every hit carries full memory content,
/// so an unbounded value is an easy way to return several megabytes by
/// accident. It is rejected rather than clamped on purpose: a caller asking
/// for 500 has misunderstood something, and quietly handing back 50 hides
/// that from them.
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct VisionSearchLimitTests {
    private func request(uri: String) -> Request {
        Request(head: .init(method: .post, scheme: "https", authority: "test", path: uri), body: .init(buffer: ByteBuffer()))
    }

    @Test
    func `absent limit falls back to the default`() throws {
        let parsed = try VisionEmbedController.parseSearchLimit(from: request(uri: "/v1/vision/search"))
        #expect(parsed == VisionEmbedController.defaultSearchLimit)
    }

    @Test
    func `an explicit limit inside the range is honoured`() throws {
        let parsed = try VisionEmbedController.parseSearchLimit(from: request(uri: "/v1/vision/search?limit=25"))
        #expect(parsed == 25)
    }

    @Test
    func `the boundaries are inclusive`() throws {
        #expect(try VisionEmbedController.parseSearchLimit(from: request(uri: "/v1/vision/search?limit=1")) == 1)
        #expect(
            try VisionEmbedController.parseSearchLimit(from: request(uri: "/v1/vision/search?limit=\(VisionEmbedController.maxSearchLimit)"))
                == VisionEmbedController.maxSearchLimit
        )
    }

    @Test
    func `out of range is rejected, not clamped`() throws {
        for raw in ["0", "-1", "\(VisionEmbedController.maxSearchLimit + 1)", "500"] {
            #expect(throws: HTTPError.self) {
                _ = try VisionEmbedController.parseSearchLimit(from: request(uri: "/v1/vision/search?limit=\(raw)"))
            }
        }
    }

    @Test
    func `a non-numeric limit is rejected rather than silently defaulted`() throws {
        // Defaulting here would turn a typo into a quietly different query.
        #expect(throws: HTTPError.self) {
            _ = try VisionEmbedController.parseSearchLimit(from: request(uri: "/v1/vision/search?limit=ten"))
        }
    }
}

/// Content-type parsing is shared by `/embed` and `/search`, and both gate on
/// an allowlist — so a media type that survives parsing with its parameters
/// attached would be rejected as unsupported even when it is fine.
@Suite(.disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct VisionContentTypeTests {
    private func request(contentType: String?) -> Request {
        var headers = HTTPFields()
        if let contentType {
            headers[.contentType] = contentType
        }
        return Request(
            head: .init(method: .post, scheme: "https", authority: "test", path: "/v1/vision/search", headerFields: headers),
            body: .init(buffer: ByteBuffer())
        )
    }

    @Test
    func `parameters and casing are stripped so the allowlist matches`() {
        #expect(VisionEmbedController.contentType(of: request(contentType: "image/png")) == "image/png")
        #expect(VisionEmbedController.contentType(of: request(contentType: "IMAGE/PNG")) == "image/png")
        #expect(VisionEmbedController.contentType(of: request(contentType: "image/jpeg; charset=binary")) == "image/jpeg")
        #expect(VisionEmbedController.contentType(of: request(contentType: " image/webp ")) == "image/webp")
    }

    @Test
    func `a missing content type yields empty rather than crashing`() {
        // Empty is not in the allowlist, so the caller gets a 415 — which is
        // the right answer for a body whose type nobody declared.
        #expect(VisionEmbedController.contentType(of: request(contentType: nil)).isEmpty)
        #expect(!VisionEmbedController.acceptedMimes.contains(""))
    }
}
