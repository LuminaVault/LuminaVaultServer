import Foundation
import Logging
import LuminaVaultShared
import NIOCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Speech-to-text over the OpenAI `/audio/transcriptions` wire format.
///
/// Named for the **wire format, not a vendor**, deliberately: the cluster's own
/// whisper service, OpenAI and Groq all serve the same multipart shape, so
/// moving between them is a base-URL change rather than a new adapter. See
/// `~/Work/production/CLAUDE.md` — paid speech APIs are not to be added, and
/// the in-cluster service at `whisper.horus.svc.cluster.local` is the default.
///
/// `baseURL` is expected to include the API version prefix (e.g.
/// `http://whisper.horus.svc.cluster.local:8000/v1`), matching how every
/// OpenAI-compatible endpoint publishes itself.
///
/// `apiKey` is optional. The in-cluster service authenticates by NetworkPolicy
/// rather than a credential, so an empty key simply omits the `Authorization`
/// header instead of sending `Bearer ` with nothing after it.
struct OpenAICompatibleTranscribeAdapter: TranscribeProviderAdapter {
    let kind: TranscribeProviderKind = .openaiCompatible
    let apiKey: String
    let baseURL: URL
    let model: String
    let session: URLSession
    let logger: Logger

    init(
        apiKey: String = "",
        baseURL: URL,
        model: String,
        session: URLSession = .shared,
        logger: Logger
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.session = session
        self.logger = logger
    }

    func transcribe(audio: ByteBuffer, mime: String) async throws -> TranscribeUpstreamResult {
        // `baseURL` already carries the version prefix, so only the endpoint
        // path is appended here. Groq's own base (`https://api.groq.com`) needs
        // `/openai/v1` included in the configured value.
        let url = baseURL
            .appendingPathComponent("audio")
            .appendingPathComponent("transcriptions")

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.buildMultipartBody(
            boundary: boundary,
            audio: Data(buffer: audio),
            filename: Self.filename(for: mime),
            mime: mime,
            model: model
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw TranscribeProviderError.network(provider: kind, underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscribeProviderError.transient(provider: kind, status: 0, body: nil)
        }
        let status = http.statusCode
        guard (200 ..< 300).contains(status) else {
            let preview = String(data: data.prefix(512), encoding: .utf8)
            if status == 429 || (500 ..< 600).contains(status) {
                logger.error("transcribe transient \(status): \(preview ?? "<binary>")")
                throw TranscribeProviderError.transient(provider: kind, status: status, body: preview)
            }
            logger.error("transcribe permanent \(status): \(preview ?? "<binary>")")
            throw TranscribeProviderError.permanent(provider: kind, status: status, body: preview)
        }

        let decoded: TranscriptionVerboseJSON
        do {
            decoded = try JSONDecoder().decode(TranscriptionVerboseJSON.self, from: data)
        } catch {
            throw TranscribeProviderError.decode(provider: kind, underlying: error)
        }

        return TranscribeUpstreamResult(
            text: decoded.text,
            language: decoded.language ?? "unknown",
            confidence: Self.aggregateConfidence(decoded.segments),
            durationSeconds: decoded.duration ?? 0,
            segments: decoded.segments?.map { TranscribeSegment(start: $0.start, end: $0.end, text: $0.text) }
        )
    }

    // MARK: - Multipart

    /// Builds an RFC-7578 multipart body containing `file` (audio bytes),
    /// `model`, `response_format=verbose_json` and `temperature=0`. Kept
    /// internal so unit tests can assert the wire shape.
    static func buildMultipartBody(
        boundary: String,
        audio: Data,
        filename: String,
        mime: String,
        model: String
    ) -> Data {
        var body = Data()
        let crlf = "\r\n"
        let prefix = "--\(boundary)\(crlf)"

        body.append(prefix.data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(audio)
        body.append(crlf.data(using: .utf8)!)

        body.append(prefix.data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\(crlf)\(crlf)".data(using: .utf8)!)
        body.append("\(model)\(crlf)".data(using: .utf8)!)

        body.append(prefix.data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\(crlf)\(crlf)".data(using: .utf8)!)
        body.append("verbose_json\(crlf)".data(using: .utf8)!)

        body.append(prefix.data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"temperature\"\(crlf)\(crlf)".data(using: .utf8)!)
        body.append("0\(crlf)".data(using: .utf8)!)

        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        return body
    }

    /// Groq and OpenAI both infer the audio decoder from the *filename
    /// extension* in the multipart part, not from its content type — a
    /// correctly-typed body sent as `audio.bin` is rejected with a 400. So
    /// every mime the API layer accepts must map to a real extension here.
    /// The `audio.bin` default is unreachable for accepted input and exists
    /// only so the function stays total.
    static func filename(for mime: String) -> String {
        switch mime {
        case "audio/m4a", "audio/x-m4a": "audio.m4a"
        case "audio/mp4": "audio.mp4"
        case "audio/wav", "audio/x-wav", "audio/wave": "audio.wav"
        case "audio/mpeg": "audio.mp3"
        case "audio/mpga": "audio.mpga"
        case "audio/webm": "audio.webm"
        case "audio/ogg", "audio/vorbis": "audio.ogg"
        case "audio/opus": "audio.opus"
        case "audio/flac", "audio/x-flac": "audio.flac"
        default: "audio.bin"
        }
    }

    /// Map per-segment `avg_logprob` (natural log of token probability) to
    /// a confidence score in `[0,1]`. `exp(avg_logprob)` recovers the
    /// geometric-mean per-segment token probability; averaging across
    /// segments gives a single number for clients. Returns 0 when there
    /// are no segments — the wire DTO requires a Double.
    static func aggregateConfidence(_ segments: [TranscriptionSegmentJSON]?) -> Double {
        guard let segments, !segments.isEmpty else { return 0 }
        let probs = segments.compactMap { seg in
            seg.avgLogprob.map { exp($0) }
        }
        guard !probs.isEmpty else { return 0 }
        let mean = probs.reduce(0, +) / Double(probs.count)
        return max(0, min(1, mean))
    }
}

// MARK: - Wire DTOs (Groq verbose_json)

struct TranscriptionVerboseJSON: Decodable {
    let text: String
    let language: String?
    let duration: Double?
    let segments: [TranscriptionSegmentJSON]?
}

struct TranscriptionSegmentJSON: Decodable {
    let start: Double
    let end: Double
    let text: String
    let avgLogprob: Double?

    enum CodingKeys: String, CodingKey {
        case start, end, text
        case avgLogprob = "avg_logprob"
    }
}
