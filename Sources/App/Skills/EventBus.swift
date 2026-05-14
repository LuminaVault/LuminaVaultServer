import Foundation
import Logging

/// Skill event taxonomy (v1). Publishers fire events from capture, health
/// and memory write paths; `SkillRunner` subscribes and dispatches any
/// skill that declares the event in its `on_event` manifest field.
enum SkillEventType: String, Hashable, Codable, CaseIterable {
    case vaultFileCreated = "vault_file_created"
    case healthEventSynced = "health_event_synced"
    case memoryUpserted = "memory_upserted"
}

/// In-process event envelope. Payload is stringly-typed for now to keep
/// the publish/subscribe surface tiny; richer typed payloads can land
/// alongside the publisher integrations as we learn what the runners need.
struct SkillEvent: Hashable {
    let type: SkillEventType
    let tenantID: UUID
    let payload: [String: String]

    /// Common payload keys publishers should use so subscribers can pull
    /// data out by a stable name. Add to this list rather than inventing
    /// per-event ad-hoc keys.
    enum PayloadKey {
        /// Vault file path, e.g. "captures/2026-05-11/foo.md".
        static let vaultPath = "vault_path"
        /// Vault file UUID as `uuidString`.
        static let vaultFileID = "vault_file_id"
        /// Memory UUID for `memory_upserted` events.
        static let memoryID = "memory_id"
        /// Optional source vault file UUID for `memory_upserted` (HER-150).
        static let sourceVaultFileID = "source_vault_file_id"
        /// HealthKit sample type identifier (e.g. "HKQuantityTypeIdentifierStepCount").
        static let healthSampleType = "health_sample_type"
        /// Count of samples in the synced batch.
        static let healthSampleCount = "health_sample_count"
    }
}

/// Tiny in-process pub/sub. No Kafka, no NATS — keep it a final class
/// with an `NSLock`-protected dictionary. Re-platform once we hit the
/// multi-replica scale that breaks single-process semantics (see HER-148
/// multi-replica notes in `docs/jobs.md`).
///
/// HER-200 H1 — previously an `actor`; subscribe had to fire a
/// `Task { await register(...) }` inside the stream factory which leaked
/// a subscriber entry if the stream dropped before the Task ran. The
/// class + lock variant registers synchronously inside the closure,
/// eliminating that race.
///
/// ## Backpressure
/// Each subscriber gets a bounded `AsyncStream` (`bufferingPolicy:
/// .bufferingNewest(64)`). When a consumer is slower than publishers,
/// the OLDEST queued event is dropped — newer signals win. We log at
/// `warning` so a missing subscriber loop surfaces quickly.
///
/// ## Failure isolation
/// A subscriber that finishes its stream (cancellation, scope exit) is
/// removed via `onTermination`. Publishers never block on subscribers.
final class EventBus: @unchecked Sendable {
    /// Per-subscriber buffer cap. 64 was picked to comfortably hold a
    /// burst of vault captures during sync without growing unbounded.
    private static let bufferCapacity = 64

    private struct Subscriber {
        let id: UUID
        let continuation: AsyncStream<SkillEvent>.Continuation
    }

    private let lock = NSLock()
    private var subscribers: [SkillEventType: [Subscriber]] = [:]
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    /// Fan-out delivery. Returns immediately even when a subscriber is
    /// backed up — `bufferingNewest` causes the OLDEST queued event to
    /// be dropped instead, and we log the drop so it can be diagnosed.
    func publish(_ event: SkillEvent) {
        lock.lock()
        let observers = subscribers[event.type] ?? []
        lock.unlock()
        guard !observers.isEmpty else { return }
        for observer in observers {
            switch observer.continuation.yield(event) {
            case .enqueued:
                continue
            case .dropped:
                logger.warning("skills.eventbus dropped event \(event.type.rawValue) for subscriber \(observer.id.uuidString)")
            case .terminated:
                // Stream already ended; cleanup will run via onTermination
                // when the underlying continuation drains.
                continue
            @unknown default:
                continue
            }
        }
    }

    /// Returns an `AsyncStream` that yields every published event of
    /// `eventType` until the stream is cancelled or the iterator is
    /// dropped. Subscribers are auto-removed on termination.
    func subscribe(eventType: SkillEventType) -> AsyncStream<SkillEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(Self.bufferCapacity)) { continuation in
            let id = UUID()
            let subscriber = Subscriber(id: id, continuation: continuation)
            self.lock.lock()
            self.subscribers[eventType, default: []].append(subscriber)
            self.lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.lock()
                subscribers[eventType]?.removeAll(where: { $0.id == id })
                lock.unlock()
            }
        }
    }

    /// Test/diagnostic helper. Returns the current subscriber count per
    /// event type. Production callers should not depend on this.
    func subscriberCount(for type: SkillEventType) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return subscribers[type]?.count ?? 0
    }
}
