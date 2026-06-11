import FluentKit
import Foundation
import LuminaVaultShared

/// Persisted record of one tenant-scoped "apply gateway config" job. One row
/// per `POST /v1/me/hermes-gateways/apply`. Persisting (rather than holding
/// state purely in memory) lets the iOS client reconnect after the app — or
/// the server — restarts mid-apply and still render an accurate snapshot via
/// `GET .../apply/{jobID}`.
///
/// `steps_json` holds the JSON-encoded `[HermesGatewayApplyStep]` array; the
/// step set is small and only ever read/written as a whole, so a JSON column
/// is simpler than a child table and keeps the snapshot atomic.
final class HermesGatewayApplyJob: Model, @unchecked Sendable {
    static let schema = "hermes_gateway_apply_jobs"

    @ID(key: .id) var id: UUID?
    /// Owning tenant — apply is per-tenant; lookups are always tenant-scoped.
    @Field(key: "tenant_id") var tenantID: UUID
    /// `HermesGatewayApplyJobState` rawValue.
    @Field(key: "state") var state: String
    /// JSON-encoded `[HermesGatewayApplyStep]`.
    @Field(key: "steps_json") var stepsJSON: String
    @OptionalField(key: "error_message") var errorMessage: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID,
        tenantID: UUID,
        state: HermesGatewayApplyJobState,
        steps: [HermesGatewayApplyStep],
        errorMessage: String? = nil
    ) {
        self.id = id
        self.tenantID = tenantID
        self.state = state.rawValue
        stepsJSON = Self.encodeSteps(steps)
        self.errorMessage = errorMessage
    }

    // MARK: - Steps codec

    static func encodeSteps(_ steps: [HermesGatewayApplyStep]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(steps),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    var steps: [HermesGatewayApplyStep] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = stepsJSON.data(using: .utf8),
              let decoded = try? decoder.decode([HermesGatewayApplyStep].self, from: data)
        else { return [] }
        return decoded
    }

    /// Build the wire snapshot DTO from this row.
    func snapshot() -> HermesGatewayApplyJobStatus {
        HermesGatewayApplyJobStatus(
            jobID: id ?? UUID(),
            state: HermesGatewayApplyJobState(rawValue: state) ?? .failed,
            steps: steps,
            errorMessage: errorMessage,
            startedAt: createdAt ?? Date(),
            updatedAt: updatedAt ?? Date()
        )
    }
}
