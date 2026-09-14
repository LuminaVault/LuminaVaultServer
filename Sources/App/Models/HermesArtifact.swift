import FluentKit
import Foundation
import LuminaVaultShared

/// One harvested image, file or link from a Hermes session (M127).
final class HermesArtifact: Model, TenantModel, @unchecked Sendable {
    static let schema = "hermes_artifacts"
    static let retainLimit = 500

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "kind") var kind: String
    @Field(key: "value") var value: String
    @Field(key: "href") var href: String
    @Field(key: "label") var label: String
    @Field(key: "session_id") var sessionID: String
    @Field(key: "session_title") var sessionTitle: String
    @Field(key: "occurred_at") var occurredAt: Date
    @Field(key: "content_hash") var contentHash: String
    @Field(key: "collected_at") var collectedAt: Date

    init() {}

    init(tenantID: UUID, record: HermesArtifactExtractor.Record, collectedAt: Date = Date()) {
        self.tenantID = tenantID
        kind = record.kind.rawValue
        value = record.value
        href = record.href
        label = record.label
        sessionID = record.sessionID
        sessionTitle = record.sessionTitle
        occurredAt = record.occurredAt
        contentHash = record.contentHash
        self.collectedAt = collectedAt
    }

    func dto() throws -> HermesArtifactDTO {
        try HermesArtifactDTO(
            id: requireID(),
            kind: HermesArtifactKind(rawValue: kind) ?? .link,
            value: value,
            href: href,
            label: label,
            sessionID: sessionID,
            sessionTitle: sessionTitle,
            occurredAt: occurredAt
        )
    }
}
