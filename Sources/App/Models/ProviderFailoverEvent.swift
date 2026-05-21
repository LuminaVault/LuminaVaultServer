import FluentKit
import Foundation

/// HER-252 — append-only telemetry row written by `ProviderFailoverLogger`
/// every time `RoutedLLMTransport` advances from one candidate to the
/// next on a recoverable failure (credit exhaustion, 429, 5xx, network).
///
/// `tenantID` is nullable + `ON DELETE SET NULL`: historical incident
/// data survives account deletion for fleet-wide analytics.
///
/// `source` is `"hosted"` (managed default gateway) or `"byo"` (user
/// override via `user_hermes_config`). Tagged from
/// `LLMRoutingContext.currentResolution`.
final class ProviderFailoverEvent: Model, @unchecked Sendable {
    static let schema = "provider_failover_events"

    @ID(key: .id) var id: UUID?
    @OptionalField(key: "tenant_id") var tenantID: UUID?
    @Field(key: "provider") var provider: String
    @OptionalField(key: "model") var model: String?
    @OptionalField(key: "status_code") var statusCode: Int?
    @OptionalField(key: "error_code") var errorCode: String?
    @OptionalField(key: "fallback_provider") var fallbackProvider: String?
    @OptionalField(key: "fallback_model") var fallbackModel: String?
    @Field(key: "source") var source: String
    @Field(key: "happened_at") var happenedAt: Date

    init() {}
}
