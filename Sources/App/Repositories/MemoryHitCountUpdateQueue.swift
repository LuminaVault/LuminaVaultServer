import Foundation
import HummingbirdFluent
import ServiceLifecycle

/// Coalesces semantic-search hit-count bumps so search never blocks on the
/// `UPDATE`, and — as a `Service` — finishes what it started before the
/// process goes away.
///
/// HER-330: the lifecycle half was missing and it mattered. Both this queue
/// and the `Task.detached` fallback it was meant to replace ran `UPDATE`s
/// against a `Fluent` nobody waited for. In production that is invisible,
/// because `Fluent` outlives every request. Under test it is fatal: the work
/// lands after `app.test` has torn the database down, `fluent.db()` trips an
/// assertion, and the assertion takes the whole test binary with it — the
/// same shape as the HER-310 teardown crash and the same reason it stayed
/// hidden, since a dead process reports no failures.
///
/// `run()` holds the service open until graceful shutdown, then drains. The
/// repository awaits the bump directly when no queue is wired, so the
/// unstructured path is gone rather than merely discouraged.
actor MemoryHitCountUpdateQueue: Service {
    private let fluent: Fluent
    private var pending: [UUID] = []
    private var worker: Task<Void, Never>?

    init(fluent: Fluent) {
        self.fluent = fluent
    }

    func enqueue(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        pending.append(contentsOf: ids)
        if worker == nil {
            worker = Task { await self.process() }
        }
    }

    func drain() async {
        // `process()` clears `worker` when the queue empties, so awaiting the
        // current one and re-checking terminates. An identity comparison here
        // would not compile — `Task` is a struct, not a class.
        while let worker {
            await worker.value
        }
    }

    func run() async throws {
        try? await gracefulShutdown()
        await drain()
    }

    private func process() async {
        while true {
            let ids = takeBatch()
            guard !ids.isEmpty else {
                worker = nil
                return
            }
            try? await MemoryRepository.bumpQueryHits(fluent: fluent, ids: ids)
        }
    }

    private func takeBatch() -> [UUID] {
        guard !pending.isEmpty else { return [] }
        let ids = Array(Set(pending))
        pending.removeAll()
        return ids
    }
}
