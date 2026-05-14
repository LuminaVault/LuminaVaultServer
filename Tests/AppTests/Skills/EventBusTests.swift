@testable import App
import Foundation
import Logging
import Testing

/// HER-171/HER-200 unit tests for `EventBus`. In-memory only — no DB, no
/// Hummingbird app required. After HER-200 H1 the bus is a `final class`
/// with an internal `NSLock`; register / unregister are synchronous, so
/// `subscriberCount(for:)` reflects the new state immediately after
/// `subscribe(...)` and after the stream is dropped.
struct EventBusTests {
    private static func makeBus() -> EventBus {
        EventBus(logger: Logger(label: "test.eventbus"))
    }

    private static func sampleEvent(
        _ type: SkillEventType = .vaultFileCreated,
        tenant: UUID = UUID(),
    ) -> SkillEvent {
        SkillEvent(
            type: type,
            tenantID: tenant,
            payload: [SkillEvent.PayloadKey.vaultPath: "notes/x.md"],
        )
    }

    @Test
    func `subscriber receives published event of matching type`() async {
        let bus = Self.makeBus()
        let stream = bus.subscribe(eventType: .vaultFileCreated)
        #expect(bus.subscriberCount(for: .vaultFileCreated) == 1)

        let event = Self.sampleEvent(.vaultFileCreated)
        bus.publish(event)

        var iter = stream.makeAsyncIterator()
        let received = await iter.next()
        #expect(received == event)
    }

    @Test
    func `subscriber ignores events of different type`() async {
        let bus = Self.makeBus()
        let vaultStream = bus.subscribe(eventType: .vaultFileCreated)
        #expect(bus.subscriberCount(for: .vaultFileCreated) == 1)

        bus.publish(Self.sampleEvent(.memoryUpserted))
        let vaultEvent = Self.sampleEvent(.vaultFileCreated)
        bus.publish(vaultEvent)

        var iter = vaultStream.makeAsyncIterator()
        let received = await iter.next()
        #expect(received == vaultEvent, "vault subscriber must not see memory events")
    }

    @Test
    func `multiple subscribers all receive event`() async {
        let bus = Self.makeBus()
        let a = bus.subscribe(eventType: .memoryUpserted)
        let b = bus.subscribe(eventType: .memoryUpserted)
        #expect(bus.subscriberCount(for: .memoryUpserted) == 2)

        let event = Self.sampleEvent(.memoryUpserted)
        bus.publish(event)

        var ai = a.makeAsyncIterator()
        var bi = b.makeAsyncIterator()
        #expect(await ai.next() == event)
        #expect(await bi.next() == event)
    }

    @Test
    func `bounded buffer drops oldest when consumer lags`() async {
        let bus = Self.makeBus()
        let stream = bus.subscribe(eventType: .vaultFileCreated)
        #expect(bus.subscriberCount(for: .vaultFileCreated) == 1)

        let tenant = UUID()
        for i in 0 ..< 100 {
            bus.publish(SkillEvent(
                type: .vaultFileCreated,
                tenantID: tenant,
                payload: [SkillEvent.PayloadKey.vaultPath: "notes/\(i).md"],
            ))
        }

        var received: [String] = []
        var iter = stream.makeAsyncIterator()
        for _ in 0 ..< 64 {
            guard let event = await iter.next() else { break }
            received.append(event.payload[SkillEvent.PayloadKey.vaultPath] ?? "")
        }
        #expect(received.count == 64)
        #expect(received.last == "notes/99.md")
        #expect(!received.contains("notes/0.md"))
    }

    @Test
    func `subscriber removed on stream termination`() async throws {
        let bus = Self.makeBus()
        do {
            let stream = bus.subscribe(eventType: .vaultFileCreated)
            #expect(bus.subscriberCount(for: .vaultFileCreated) == 1)
            _ = stream
        }
        // HER-200 H1 — onTermination unregisters synchronously inside its
        // closure, but the closure itself is invoked by AsyncStream as the
        // continuation drains. Give the runtime a tick so the closure fires.
        try await Self.waitForSubscriberCount(bus, type: .vaultFileCreated, expected: 0)
    }

    @Test
    func `publish with no subscribers is noop`() {
        let bus = Self.makeBus()
        bus.publish(Self.sampleEvent(.vaultFileCreated))
        #expect(bus.subscriberCount(for: .vaultFileCreated) == 0)
    }

    // MARK: - HER-200 H1 specific tests

    @Test
    func `HER-200 H1 subscribe registers synchronously without Task hop`() {
        let bus = Self.makeBus()
        // No `await`, no waiting. After subscribe returns, the subscriber
        // is registered. Catches regression to the actor + fire-and-forget
        // Task pattern that previously leaked subscribers on early drop.
        let stream = bus.subscribe(eventType: .healthEventSynced)
        #expect(bus.subscriberCount(for: .healthEventSynced) == 1)
        _ = stream
    }

    @Test
    func `HER-200 H1 dropped stream before any publish unregisters cleanly`() async throws {
        let bus = Self.makeBus()
        for _ in 0 ..< 50 {
            // Drop the stream immediately; this is the race the actor
            // version leaked. With the class+lock, unregister is sync inside
            // onTermination, so the buffer drains to zero.
            _ = bus.subscribe(eventType: .vaultFileCreated)
        }
        try await Self.waitForSubscriberCount(bus, type: .vaultFileCreated, expected: 0)
    }

    @Test
    func `HER-200 H1 concurrent subscribe and publish does not deadlock`() async {
        let bus = Self.makeBus()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 10 {
                group.addTask {
                    let stream = bus.subscribe(eventType: .vaultFileCreated)
                    var iter = stream.makeAsyncIterator()
                    _ = await iter.next()
                }
            }
            // Allow subscribers a moment to register before publishing.
            try? await Task.sleep(nanoseconds: 20_000_000)
            for _ in 0 ..< 10 {
                bus.publish(Self.sampleEvent(.vaultFileCreated))
            }
        }
    }

    // MARK: - Helpers

    /// Polls `bus.subscriberCount(for:)` until it matches `expected` or the
    /// 2 s budget elapses. After HER-200 H1 register/unregister are sync, so
    /// this is only needed for paths where the AsyncStream runtime invokes
    /// `onTermination` lazily as the continuation drains.
    private static func waitForSubscriberCount(
        _ bus: EventBus,
        type: SkillEventType,
        expected: Int,
        timeoutNanos: UInt64 = 2_000_000_000,
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            let count = bus.subscriberCount(for: type)
            if count == expected { return }
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanos {
                Issue.record("subscriberCount(for: \(type)) timed out: got \(count), expected \(expected)")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
