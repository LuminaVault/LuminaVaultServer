import Foundation
import LuminaVaultShared

enum WorkflowSchedulePolicyError: Error, Equatable {
    case invalidCron
    case scheduleTooFrequent(minimumMinutes: Int)
}

enum WorkflowSchedulePolicy {
    static func validate(definition: WorkflowDefinitionDTO, minimumMinutes: Int) throws {
        guard definition.trigger == .schedule else { return }
        guard minimumMinutes > 0 else { throw WorkflowSchedulePolicyError.scheduleTooFrequent(minimumMinutes: minimumMinutes) }
        guard let rawCron = definition.triggerConfiguration["cron"] else {
            // One-shot `runAt` schedules are not recurring and therefore do
            // not need a frequency check.
            guard definition.triggerConfiguration["runAt"] != nil else {
                throw WorkflowSchedulePolicyError.invalidCron
            }
            return
        }
        guard let cron = try? CronExpression(rawCron) else { throw WorkflowSchedulePolicyError.invalidCron }
        let timezone = TimeZone(identifier: definition.triggerConfiguration["timezone"] ?? "UTC")
            ?? TimeZone(secondsFromGMT: 0)
            ?? .current
        let start = Date.now.addingTimeInterval(-Date.now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60))
        var previous: Date?
        // Any schedule violating the Pro/Ultimate 60m/5m floor will expose
        // two adjacent occurrences inside this 48-hour window.
        for minute in 0 ..< (48 * 60) {
            let candidate = start.addingTimeInterval(TimeInterval(minute * 60))
            guard cron.matches(candidate, in: timezone) else { continue }
            if let previous, candidate.timeIntervalSince(previous) < TimeInterval(minimumMinutes * 60) {
                throw WorkflowSchedulePolicyError.scheduleTooFrequent(minimumMinutes: minimumMinutes)
            }
            previous = candidate
        }
    }
}
