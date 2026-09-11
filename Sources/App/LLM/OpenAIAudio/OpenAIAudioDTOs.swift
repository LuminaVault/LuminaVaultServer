import Foundation
import Hummingbird

// MARK: - Error envelope

/// OpenAI's error body shape.
///
/// This is load-bearing, not cosmetic. The OpenAI Python SDK reads
/// `body["error"]["message"]` when it raises `APIStatusError`, and Hermes
/// surfaces that message to the user. Return anything else and a rate-limit
/// rejection reaches a Telegram user as `Error code: 429 - {...}` instead of
/// the sentence we wrote for them.
struct OpenAIErrorEnvelope: Codable, ResponseEncodable {
    struct Payload: Codable {
        let message: String
        let type: String
        let code: String?
        let param: String?
    }

    let error: Payload

    init(message: String, type: String, code: String? = nil, param: String? = nil) {
        error = Payload(message: message, type: type, code: code, param: param)
    }

    /// Conventional `type` values, matching what the SDK's consumers expect.
    static func invalidRequest(_ message: String, code: String? = nil, param: String? = nil) -> Self {
        .init(message: message, type: "invalid_request_error", code: code, param: param)
    }

    static func rateLimit(_ message: String) -> Self {
        .init(message: message, type: "rate_limit_error", code: "rate_limit_exceeded")
    }

    static func insufficientQuota(_ message: String) -> Self {
        .init(message: message, type: "insufficient_quota", code: "insufficient_quota")
    }

    static func authentication(_ message: String) -> Self {
        .init(message: message, type: "authentication_error", code: "invalid_api_key")
    }

    static func server(_ message: String, code: String? = nil) -> Self {
        .init(message: message, type: "server_error", code: code)
    }
}

// MARK: - Transcription responses

/// `response_format=json` — the default the OpenAI SDK casts to.
struct OpenAITranscriptionJSON: Codable, ResponseEncodable {
    let text: String
}

/// `response_format=verbose_json`. Field names and units follow OpenAI:
/// `duration` in seconds, segments carrying absolute start/end offsets.
struct OpenAIVerboseTranscriptionJSON: Codable, ResponseEncodable {
    struct Segment: Codable {
        let id: Int
        let start: Double
        let end: Double
        let text: String
    }

    let task: String
    let language: String
    let duration: Double
    let text: String
    let segments: [Segment]

    init(from response: TranscribeResponse) {
        task = "transcribe"
        language = response.language
        duration = response.durationSeconds
        text = response.text
        segments = (response.segments ?? []).enumerated().map { index, segment in
            Segment(id: index, start: segment.start, end: segment.end, text: segment.text)
        }
    }
}

/// The `response_format` values this surface supports.
///
/// Hermes picks between them by model — `whisper-1` gets `text`, everything
/// else gets `json` — so supporting only one is not an option.
enum OpenAITranscriptionFormat: String, Sendable {
    case json
    case text
    case verboseJSON = "verbose_json"
    /// Accepted and served as plain text; we do not produce real subtitle
    /// timing tracks, and no caller on this path asks for them.
    case srt
    case vtt

    init(rawValueOrDefault raw: String?) {
        guard let raw, let parsed = OpenAITranscriptionFormat(rawValue: raw.lowercased()) else {
            self = .json
            return
        }
        self = parsed
    }

    /// True when the response body is plain text rather than JSON.
    var isPlainText: Bool {
        switch self {
        case .text, .srt, .vtt: true
        case .json, .verboseJSON: false
        }
    }
}

// MARK: - Speech request

/// `POST /v1/audio/speech` request body.
struct OpenAISpeechRequest: Decodable {
    let model: String?
    let input: String
    let voice: String?
    let responseFormat: String?
    let speed: Double?

    enum CodingKeys: String, CodingKey {
        case model, input, voice, speed
        case responseFormat = "response_format"
    }
}
