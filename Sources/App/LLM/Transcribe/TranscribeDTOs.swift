import Foundation
import Hummingbird

// HER-213: TranscribeSegment + TranscribeResponse were pruned from
// LuminaVaultShared v0.11.0 per the "wire-types-only" boundary. They now
// live server-side; the iOS client builds its own decoders.

struct TranscribeSegment: Codable, Sendable {
    let start: Double
    let end: Double
    let text: String
    init(start: Double, end: Double, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

struct TranscribeResponse: Codable, Sendable {
    let id: String
    let text: String
    let language: String
    let confidence: Double
    let durationSeconds: Double
    let segments: [TranscribeSegment]?
    enum CodingKeys: String, CodingKey {
        case id, text, language, confidence
        case durationSeconds = "duration_seconds"
        case segments
    }
    init(id: String, text: String, language: String, confidence: Double, durationSeconds: Double, segments: [TranscribeSegment]? = nil) {
        self.id = id; self.text = text; self.language = language
        self.confidence = confidence; self.durationSeconds = durationSeconds
        self.segments = segments
    }
}

extension TranscribeResponse: ResponseEncodable {}
