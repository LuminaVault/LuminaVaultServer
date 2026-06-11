import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import ServiceLifecycle

/// `ServiceLifecycle.Service` that wakes once per minute and fires any
/// reminder whose `fireAt` has arrived and `firedAt` is still nil. Mirrors
/// `CronScheduler`'s single-replica, next-occurrence design.
///
/// ## Constraints
/// - **In-process, single-replica.** Multi-replica = double-fire (same caveat
///   as `CronScheduler`; add advisory-lock leader election when we scale out).
/// - **Catch-up on the next tick, not replay.** A reminder whose `fireAt` is
///   in the past (e.g. server was down) fires on the next tick — `fire_at <= now`
///   is the predicate, so missed one-shots still deliver once.
/// - One-shot reminders stamp `firedAt`. Recurring reminders advance `fireAt`
///   to the next cron match and leave `firedAt` nil so they re-arm.
actor ReminderScheduler: Service {
    private let tickInterval: Duration
    private let maxConcurrent: Int
    private let fluent: Fluent
    private let push: APNSNotificationService?
    private let logger: Logger

    init(
        fluent: Fluent,
        push: APNSNotificationService?,
        logger: Logger,
        tickInterval: Duration = .seconds(60),
        maxConcurrent: Int = 4
    ) {
        self.fluent = fluent
        self.push = push
        self.logger = logger
        self.tickInterval = tickInterval
        self.maxConcurrent = maxConcurrent
    }

    func run() async throws {
        logger.info("reminders.scheduler started (tick=\(tickInterval))")
        try? await Task.sleep(for: .seconds(secondsUntilNextMinute(now: Date())))
        while !Task.isCancelled {
            do {
                let fired = try await tick(at: Date())
                if fired > 0 { logger.info("reminders.tick fired=\(fired)") }
            } catch {
                logger.warning("reminders.tick error \(error)")
            }
            try? await Task.sleep(for: tickInterval)
        }
    }

    /// Single tick — fires every due reminder, returns the count fired.
    /// Exposed so tests can drive ticks deterministically.
    @discardableResult
    func tick(at now: Date) async throws -> Int {
        guard !fluent.databases.ids().isEmpty else { return 0 }
        let due = try await Reminder.query(on: fluent.db())
            .filter(\.$firedAt == nil)
            .filter(\.$fireAt <= now)
            .all()
        guard !due.isEmpty else { return 0 }
        await dispatchBounded(due, now: now)
        return due.count
    }

    // MARK: - Dispatch

    private func dispatchBounded(_ reminders: [Reminder], now: Date) async {
        await withTaskGroup(of: Void.self) { group in
            var queue = reminders.makeIterator()
            var inFlight = 0
            func spawnNext() {
                guard let next = queue.next() else { return }
                inFlight += 1
                group.addTask { [self] in await fire(next, now: now) }
            }
            for _ in 0 ..< min(maxConcurrent, reminders.count) {
                spawnNext()
            }
            while inFlight > 0 {
                _ = await group.next()
                inFlight -= 1
                spawnNext()
            }
        }
    }

    /// Fires one reminder's push, then advances/stamps its state. Push
    /// failures never block the state update — otherwise a dead token would
    /// re-fire the same reminder forever.
    private func fire(_ reminder: Reminder, now: Date) async {
        let tenantID = reminder.tenantID
        if let push {
            do {
                try await push.notifyReminder(userID: tenantID, title: reminder.title, body: reminder.body)
            } catch {
                logger.warning("reminders.push failed tenant=\(tenantID): \(error)")
            }
        }
        // Advance recurring reminders; stamp one-shots.
        if let cronRaw = reminder.recurrenceCron,
           let expression = try? CronExpression(cronRaw),
           let next = Self.nextOccurrence(of: expression, after: now)
        {
            reminder.fireAt = next
            reminder.firedAt = nil
        } else {
            reminder.firedAt = now
        }
        do {
            try await reminder.save(on: fluent.db())
        } catch {
            logger.warning("reminders.persist failed tenant=\(tenantID): \(error)")
        }
    }

    // MARK: - Helpers

    /// Next minute (in GMT) at which `expression` matches, searching forward
    /// from `after`. Capped at 366 days so a pathological expression that
    /// never matches falls back to one-shot behavior (returns nil).
    static func nextOccurrence(of expression: CronExpression, after: Date) -> Date? {
        let calendar = Calendar(identifier: .gregorian)
        // Start at the next whole minute after `after`.
        var candidate = after.addingTimeInterval(60 - Double(calendar.component(.second, from: after)))
        let cap = after.addingTimeInterval(366 * 24 * 60 * 60)
        while candidate <= cap {
            if expression.matches(candidate, in: .gmt) { return candidate }
            candidate.addTimeInterval(60)
        }
        return nil
    }

    private func secondsUntilNextMinute(now: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let seconds = calendar.dateComponents([.second], from: now).second ?? 0
        return max(1, 60 - seconds)
    }
}
