import FluentKit
import Foundation

/// Recent task-based connection diagnostics for Settings. These rows are
/// intentionally small and human-facing; source-specific logs remain in their
/// subsystem tables.
final class ConnectionDiagnosticEvent: Model, TenantModel, @unchecked Sendable {
    static let schema = "connection_diagnostic_events"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "occurred_at") var occurredAt: Date
    @Field(key: "kind") var kind: String
    @OptionalField(key: "connection_id") var connectionID: String?
    @OptionalField(key: "connection_title") var connectionTitle: String?
    @Field(key: "severity") var severity: String
    @Field(key: "message") var message: String
    @OptionalField(key: "code") var code: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
}
