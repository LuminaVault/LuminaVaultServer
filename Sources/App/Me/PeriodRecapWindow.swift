import Foundation
import LuminaVaultShared

/// The local calendar a year or month recap is cut from. Pure: no I/O.
///
/// A running period is clamped to the end of today, and the comparison
/// window is the same stretch one year (or one month) earlier, so "2026 so
/// far" on 16 October is compared with 1 January–16 October 2025, not with
/// all of 2025.
struct PeriodRecapWindow: Equatable {
    struct Day: Equatable {
        /// `yyyy-MM-dd`.
        let key: String
        /// 1 = Monday … 7 = Sunday.
        let weekday: Int
    }

    let kind: RecapPeriodKind
    let year: Int
    let month: Int?
    /// A valid IANA identifier; `UTC` when the stored one is not.
    let timezone: String
    /// Local midnight at the start of the period.
    let start: Date
    /// Exclusive: local midnight after the last day covered.
    let end: Date
    /// Exclusive: local midnight after the period's last day.
    let periodEnd: Date
    let previousStart: Date
    let previousEnd: Date
    /// Every local day covered, oldest first. Empty for a future period.
    let days: [Day]
    /// Series bucket keys, oldest first: `yyyy-MM` for a year, the day keys
    /// for a month.
    let bucketKeys: [String]
    let isComplete: Bool
    let isFuture: Bool

    /// `nil` when the year or month is out of range.
    init?(kind: RecapPeriodKind, year: Int, month: Int?, timezone requested: String, now: Date) {
        guard (2000 ... 9999).contains(year) else { return nil }
        let zone = TimeZone(identifier: requested)
        timezone = zone == nil ? "UTC" : requested
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? .gmt

        let step: Calendar.Component
        let startComponents: DateComponents
        switch kind {
        case .year:
            guard month == nil else { return nil }
            step = .year
            startComponents = DateComponents(year: year, month: 1, day: 1)
        case .month:
            guard let month, (1 ... 12).contains(month) else { return nil }
            step = .month
            startComponents = DateComponents(year: year, month: month, day: 1)
        }
        guard let start = calendar.date(from: startComponents),
              let periodEnd = calendar.date(byAdding: step, value: 1, to: start),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        else { return nil }

        self.kind = kind
        self.year = year
        self.month = kind == .month ? month : nil
        self.start = start
        self.periodEnd = periodEnd
        isFuture = now < start
        isComplete = now >= periodEnd
        let end = isFuture ? start : min(periodEnd, tomorrow)
        self.end = end
        previousStart = calendar.date(byAdding: step, value: -1, to: start) ?? start
        previousEnd = min(calendar.date(byAdding: step, value: -1, to: end) ?? start, start)

        var days: [Day] = []
        var cursor = start
        while cursor < end {
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: cursor)
            days.append(Day(
                key: String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0),
                // Calendar weekday: 1 = Sunday. Shift to ISO, Monday first.
                weekday: ((c.weekday ?? 1) + 5) % 7 + 1
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        self.days = days

        switch kind {
        case .year:
            var months: [String] = []
            for day in days where !months.contains(String(day.key.prefix(7))) {
                months.append(String(day.key.prefix(7)))
            }
            bucketKeys = months
        case .month:
            bucketKeys = days.map(\.key)
        }
    }

    /// `2026` or `2026-10`.
    var periodKey: String {
        if let month {
            return String(format: "%04d-%02d", year, month)
        }
        return String(format: "%04d", year)
    }

    var startKey: String {
        days.first?.key ?? ""
    }

    var endKey: String {
        days.last?.key ?? ""
    }
}
