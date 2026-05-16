import Foundation
import Hummingbird

// HER-213: HealthEventDTO + HealthListResponse were pruned from
// LuminaVaultShared v0.11.0 (carry server-side `id` populated post-insert,
// outside the wire-types-only boundary). They live server-side now.

struct HealthEventDTO: Codable, Sendable {
    let id: UUID
    let type: String
    let recordedAt: Date
    let valueNumeric: Double?
    let valueText: String?
    let unit: String?
    let source: String?
    let metadata: [String: String]?
    init(
        id: UUID,
        type: String,
        recordedAt: Date,
        valueNumeric: Double? = nil,
        valueText: String? = nil,
        unit: String? = nil,
        source: String? = nil,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.type = type
        self.recordedAt = recordedAt
        self.valueNumeric = valueNumeric
        self.valueText = valueText
        self.unit = unit
        self.source = source
        self.metadata = metadata
    }
}

struct HealthListResponse: Codable, Sendable {
    let events: [HealthEventDTO]
    let limit: Int
    let offset: Int
    init(events: [HealthEventDTO], limit: Int, offset: Int) {
        self.events = events
        self.limit = limit
        self.offset = offset
    }
}

extension HealthEventDTO: ResponseEncodable {}
extension HealthListResponse: ResponseEncodable {}
