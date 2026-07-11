import Foundation
import HummingbirdFluent

actor MemoryHitCountUpdateQueue {
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
        while let worker {
            await worker.value
        }
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
