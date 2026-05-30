import FluentKit
import Foundation
import LuminaVaultShared

/// HER-330 — persisted record of one "Update Hermes" job. One row per
/// owner-triggered update. Persisting (rather than holding job state purely
/// in memory) lets the iOS client reconnect after the app — or the server —
/// restarts mid-update and still render an accurate snapshot via
/// `GET /v1/system/hermes/update/{jobID}` and `…/current`.
///
/// `steps_json` holds the JSON-encoded `[HermesUpdateStep]` array; the
/// step set is small and only ever read/written as a whole, so a JSON column
/// is simpler than a child table and keeps the snapshot atomic.
final class HermesUpdateJob: Model, @unchecked Sendable {
    static let schema = "hermes_update_jobs"

    @ID(key: .id) var id: UUID?
    /// `HermesUpdateJobState` rawValue.
    @Field(key: "state") var state: String
    /// JSON-encoded `[HermesUpdateStep]`.
    @Field(key: "steps_json") var stepsJSON: String
    /// Image ref/version running before the update (rollback target).
    @OptionalField(key: "from_version") var fromVersion: String?
    /// Target image ref/version this job moves to.
    @OptionalField(key: "to_version") var toVersion: String?
    @OptionalField(key: "error_message") var errorMessage: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID,
        state: HermesUpdateJobState,
        steps: [HermesUpdateStep],
        fromVersion: String?,
        toVersion: String?,
        errorMessage: String? = nil,
    ) {
        self.id = id
        self.state = state.rawValue
        self.stepsJSON = Self.encodeSteps(steps)
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.errorMessage = errorMessage
    }

    // MARK: - Steps codec

    static func encodeSteps(_ steps: [HermesUpdateStep]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(steps),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    var steps: [HermesUpdateStep] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = stepsJSON.data(using: .utf8),
              let decoded = try? decoder.decode([HermesUpdateStep].self, from: data)
        else { return [] }
        return decoded
    }

    /// Build the wire snapshot DTO from this row.
    func snapshot() -> HermesUpdateJobStatus {
        HermesUpdateJobStatus(
            jobID: id ?? UUID(),
            state: HermesUpdateJobState(rawValue: state) ?? .failed,
            steps: steps,
            fromVersion: fromVersion,
            toVersion: toVersion,
            errorMessage: errorMessage,
            startedAt: createdAt ?? Date(),
            updatedAt: updatedAt ?? Date(),
        )
    }
}
