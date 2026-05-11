import Foundation
import Logging
import Testing

@testable import App

/// HER-171 unit tests for `EventBus`. In-memory only — no DB, no Hummingbird
/// app required. The actor is the source of truth for pub/sub semantics.
@Suite
struct EventBusTests {
    private static func makeBus() -> EventBus {
        EventBus(logger: Logger(label: "test.eventbus"))
    }

    private static func sampleEvent(
        _ type: SkillEventType = .vaultFileCreated,
        tenant: UUID = UUID()
    ) -> SkillEvent {
        SkillEvent(
            type: type,
            tenantID: tenant,
            payload: [SkillEvent.PayloadKey.vaultPath: "notes/x.md"]
        )
    }

    @Test
    func subscriberReceivesPublishedEventOfMatchingType() async throws {
        let bus = Self.makeBus()
        let stream = bus.subscribe(eventType: .vaultFileCreated)
        // Subscription registration is dispatched onto the actor in a Task;
        // wait a beat so the bus has the subscriber before publish.
        try await Self.waitForSubscriberCount(bus, type: .vaultFileCreated, expected: 1)

        let event = Self.sampleEvent(.vaultFileCreated)
        await bus.publish(event)

        var iter = stream.makeAsyncIterator()
        let received = await iter.next()
        #expect(received == event)
    }

    @Test
    func subscriberIgnoresEventsOfDifferentType() async throws {
        let bus = Self.makeBus()
        let vaultStream = bus.subscribe(eventType: .vaultFileCreated)
        try await Self.waitForSubscriberCount(bus, type: .vaultFileCreated, expected: 1)

        // Publish a memory event while the vault subscriber is listening.
        await bus.publish(Self.sampleEvent(.memoryUpserted))
        // Publish a matching vault event next.
        let vaultEvent = Self.sampleEvent(.vaultFileCreated)
        await bus.publish(vaultEvent)

        var iter = vaultStream.makeAsyncIterator()
        let received = await iter.next()
        #expect(received == vaultEvent, "vault subscriber must not see memory events")
    }

    @Test
    func multipleSubscribersAllReceiveEvent() async throws {
        let bus = Self.makeBus()
        let a = bus.subscribe(eventType: .memoryUpserted)
        let b = bus.subscribe(eventType: .memoryUpserted)
        try await Self.waitForSubscriberCount(bus, type: .memoryUpserted, expected: 2)

        let event = Self.sampleEvent(.memoryUpserted)
        await bus.publish(event)

        var ai = a.makeAsyncIterator()
        var bi = b.makeAsyncIterator()
        #expect(await ai.next() == event)
        #expect(await bi.next() == event)
    }

    @Test
    func boundedBufferDropsOldestWhenConsumerLags() async throws {
        // Buffer cap is 64. Publish 100 events without consuming; only the
        // most recent 64 should be retained. Consume all and assert we get
        // exactly 64 deliveries, with the latest being the 100th publish.
        let bus = Self.makeBus()
        let stream = bus.subscribe(eventType: .vaultFileCreated)
        try await Self.waitForSubscriberCount(bus, type: .vaultFileCreated, expected: 1)

        let tenant = UUID()
        for i in 0 ..< 100 {
            await bus.publish(SkillEvent(
                type: .vaultFileCreated,
                tenantID: tenant,
                payload: [SkillEvent.PayloadKey.vaultPath: "notes/\(i).md"]
            ))
        }

        var received: [String] = []
        var iter = stream.makeAsyncIterator()
        // Drain in a bounded loop with a timeout so a buggy bus doesn't
        // hang the test. We expect exactly 64 events queued.
        for _ in 0 ..< 64 {
            guard let event = await iter.next() else { break }
            received.append(event.payload[SkillEvent.PayloadKey.vaultPath] ?? "")
        }
        #expect(received.count == 64)
        #expect(received.last == "notes/99.md")
        // The earliest 36 must have been dropped.
        #expect(!received.contains("notes/0.md"))
    }

    @Test
    func subscriberRemovedOnStreamTermination() async throws {
        let bus = Self.makeBus()
        do {
            // The stream must be held in a named local so it lives for the
            // duration of the `do` block. `_ = bus.subscribe(...)` drops the
            // stream immediately (the wildcard pattern is a discard, not a
            // bind), which causes onTermination to fire before the actor's
            // registration Task has had a chance to run.
            let stream = bus.subscribe(eventType: .vaultFileCreated)
            try await Self.waitForSubscriberCount(bus, type: .vaultFileCreated, expected: 1)
            _ = stream // suppress "never used" — the side effect is liveness
        }
        // Stream was dropped at scope exit. onTermination fires asynchronously
        // via a Task hop onto the actor, so wait for the cleanup.
        try await Self.waitForSubscriberCount(bus, type: .vaultFileCreated, expected: 0)
    }

    @Test
    func publishWithNoSubscribersIsNoop() async {
        let bus = Self.makeBus()
        await bus.publish(Self.sampleEvent(.vaultFileCreated))
        let count = await bus.subscriberCount(for: .vaultFileCreated)
        #expect(count == 0)
    }

    // MARK: - Helpers

    /// Polls `bus.subscriberCount(for:)` until it matches `expected` or the
    /// 2s budget elapses. Needed because `subscribe` dispatches registration
    /// onto the actor via a Task — synchronous return means the bus hasn't
    /// stored the continuation yet.
    private static func waitForSubscriberCount(
        _ bus: EventBus,
        type: SkillEventType,
        expected: Int,
        timeoutNanos: UInt64 = 2_000_000_000
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            let count = await bus.subscriberCount(for: type)
            if count == expected { return }
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanos {
                Issue.record("subscriberCount(for: \(type)) timed out: got \(count), expected \(expected)")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
    }
}
