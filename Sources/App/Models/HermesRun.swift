import FluentKit
import Foundation
import LuminaVaultShared

/// Phase 1 — an agent run LuminaVault started on the tenant's Hermes
/// (`POST /v1/runs`). Schema in M117. The run watcher owns every write
/// after insert; request handlers only read (and set `pending_approval`
/// to nil after a successful approval round-trip).
final class HermesRun: Model, TenantModel, @unchecked Sendable {
    static let schema = "hermes_runs"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "hermes_run_id") var hermesRunID: String
    @Field(key: "status") var status: String
    @Field(key: "prompt") var prompt: String
    @OptionalField(key: "session_id") var sessionID: String?
    @OptionalField(key: "model") var model: String?
    @OptionalField(key: "conversation_id") var conversationID: UUID?
    @Field(key: "started_at") var startedAt: Date
    @OptionalField(key: "finished_at") var finishedAt: Date?
    @OptionalField(key: "last_event") var lastEvent: String?
    @Field(key: "last_seq") var lastSeq: Int
    @OptionalField(key: "pending_approval") var pendingApproval: HermesRunPendingApprovalDTO?
    @OptionalField(key: "summary") var summary: String?
    @OptionalField(key: "error") var error: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tenantID: UUID,
        hermesRunID: String,
        status: HermesRunStatus = .queued,
        prompt: String,
        sessionID: String? = nil,
        model: String? = nil,
        conversationID: UUID? = nil,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.tenantID = tenantID
        self.hermesRunID = hermesRunID
        self.status = status.rawValue
        self.prompt = prompt
        self.sessionID = sessionID
        self.model = model
        self.conversationID = conversationID
        self.startedAt = startedAt
        lastSeq = 0
    }

    /// Typed view of `status`; unknown strings read as `lost` so a corrupt
    /// row never masquerades as active.
    var runStatus: HermesRunStatus {
        get { HermesRunStatus(rawValue: status) ?? .lost }
        set { status = newValue.rawValue }
    }

    func toDTO() throws -> HermesRunDTO {
        try HermesRunDTO(
            id: requireID(),
            hermesRunID: hermesRunID,
            status: runStatus,
            prompt: prompt,
            sessionID: sessionID,
            model: model,
            conversationID: conversationID,
            startedAt: startedAt,
            finishedAt: finishedAt,
            lastEvent: lastEvent,
            lastSeq: lastSeq,
            pendingApproval: pendingApproval,
            summary: summary,
            error: error
        )
    }
}

/// Phase 1 — one persisted Hermes SSE event. Schema in M118.
final class HermesRunEventRow: Model, @unchecked Sendable {
    static let schema = "hermes_run_events"

    @ID(key: .id) var id: UUID?
    @Field(key: "run_id") var runID: UUID
    @Field(key: "seq") var seq: Int
    @Field(key: "event") var event: String
    @Field(key: "payload") var payload: AnyJSONValue
    @Field(key: "at") var at: Date

    init() {}

    init(id: UUID? = nil, runID: UUID, seq: Int, event: String, payload: AnyJSONValue, at: Date = Date()) {
        self.id = id
        self.runID = runID
        self.seq = seq
        self.event = event
        self.payload = payload
        self.at = at
    }

    func toDTO() -> HermesRunEventDTO {
        HermesRunEventDTO(runID: runID, seq: seq, event: event, payload: payload, at: at)
    }
}
