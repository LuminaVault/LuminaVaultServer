import Foundation
import Logging

/// Skill event taxonomy (v1). Publishers fire events from capture, health
/// and memory write paths; `SkillRunner` subscribes and dispatches any
/// skill that declares the event in its `on_event` manifest field.
enum SkillEventType: String, Sendable, Hashable, Codable {
    case vaultFileCreated = "vault_file_created"
    case healthEventSynced = "health_event_synced"
    case memoryUpserted = "memory_upserted"
}

/// In-process event envelope. Payload is stringly-typed for now to keep
/// the publish/subscribe surface tiny; richer typed payloads can land
/// alongside the publisher integrations in HER-171.
struct SkillEvent: Sendable, Hashable {
    let type: SkillEventType
    let tenantID: UUID
    let payload: [String: String]
}

/// Tiny in-process pub/sub actor. No Kafka, no NATS — keep it `actor`
/// plus a `[EventType: [Continuation]]` map. Re-platform once we hit
/// the multi-replica scale that breaks single-process semantics
/// (see HER-148 multi-replica notes in `docs/jobs.md`).
///
/// HER-148 scaffold: actor surface + no-op implementations. Real
/// pub/sub + bounded buffer + drop-oldest semantics in HER-171.
actor EventBus {
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func publish(_ event: SkillEvent) async {
        // HER-171: fan out to subscribers, drop-oldest on bounded buffer.
    }

    func subscribe(eventType: SkillEventType) -> AsyncStream<SkillEvent> {
        // HER-171: register a Continuation in the per-type subscriber map.
        AsyncStream { _ in }
    }
}
