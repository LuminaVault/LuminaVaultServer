import Foundation
import Logging
import LuminaVaultShared
import NIOCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-203 — `TranscribeProviderAdapter` wrapping Groq's Whisper endpoint.
/// Groq exposes an OpenAI-compatible `/openai/v1/audio/transcriptions`
/// surface — the same multipart/form-data shape OpenAI Whisper accepts.
/// Selected at boot when `transcribe.provider=groq` (default) and
/// `transcribe.provider.groq.apiKey` is non-empty.
struct GroqWhisperAdapter: TranscribeProviderAdapter {
    let kind: TranscribeProviderKind = .groq
    let apiKey: String
    let baseURL: URL
    let model: String
    let session: URLSession
    let logger: Logger

    init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.groq.com")!,
        model: String = "whisper-large-v3",
        session: URLSession = .shared,
        logger: Logger,
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.session = session
        self.logger = logger
    }

    func transcribe(audio: ByteBuffer, mime: String) async throws -> TranscribeUpstreamResult {
        let url = baseURL
            .appendingPathComponent("openai")
            .appendingPathComponent("v1")
            .appendingPathComponent("audio")
            .appendingPathComponent("transcriptions")

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.buildMultipartBody(
            boundary: boundary,
            audio: Data(buffer: audio),
            filename: Self.filename(for: mime),
            mime: mime,
            model: model,
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
                logger.error("groq whisper transient \(status): \(preview ?? "<binary>")")
                throw TranscribeProviderError.transient(provider: kind, status: status, body: preview)
            }
            logger.error("groq whisper permanent \(status): \(preview ?? "<binary>")")
            throw TranscribeProviderError.permanent(provider: kind, status: status, body: preview)
        }

        let decoded: GroqVerboseJSON
        do {
            decoded = try JSONDecoder().decode(GroqVerboseJSON.self, from: data)
        } catch {
            throw TranscribeProviderError.decode(provider: kind, underlying: error)
        }

        return TranscribeUpstreamResult(
            text: decoded.text,
            language: decoded.language ?? "unknown",
            confidence: Self.aggregateConfidence(decoded.segments),
            durationSeconds: decoded.duration ?? 0,
            segments: decoded.segments?.map { TranscribeSegment(start: $0.start, end: $0.end, text: $0.text) },
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
        model: String,
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

    static func filename(for mime: String) -> String {
        switch mime {
        case "audio/m4a": "audio.m4a"
        case "audio/wav": "audio.wav"
        case "audio/mpeg": "audio.mp3"
        case "audio/webm": "audio.webm"
        default: "audio.bin"
        }
    }

    /// Map per-segment `avg_logprob` (natural log of token probability) to
    /// a confidence score in `[0,1]`. `exp(avg_logprob)` recovers the
    /// geometric-mean per-segment token probability; averaging across
    /// segments gives a single number for clients. Returns 0 when there
    /// are no segments — the wire DTO requires a Double.
    static func aggregateConfidence(_ segments: [GroqSegment]?) -> Double {
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

struct GroqVerboseJSON: Decodable {
    let text: String
    let language: String?
    let duration: Double?
    let segments: [GroqSegment]?
}

struct GroqSegment: Decodable {
    let start: Double
    let end: Double
    let text: String
    let avgLogprob: Double?

    enum CodingKeys: String, CodingKey {
        case start, end, text
        case avgLogprob = "avg_logprob"
    }
}
