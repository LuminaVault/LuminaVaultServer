import Foundation

/// Minimal POSIX-style 5-field cron expression evaluator.
///
/// Fields, in order: `minute hour day-of-month month day-of-week`.
/// Field syntax supported:
///   * `*`         — wildcard
///   * `5`         — literal
///   * `1,3,5`     — comma list of literals
///   * `1-5`       — inclusive range
///   * `*/15`      — step
///   * `1-30/5`    — range with step
///
/// `dow` is 0–6 (0 = Sunday). `mon` is 1–12.
/// Day-of-month vs day-of-week semantics: when BOTH are `*`, the date
/// matches every day. When EITHER is restricted, the date matches if the
/// restricted field matches (POSIX cron OR-semantics — different from
/// some spec readings, but matches what every real cron implementation
/// does in practice).
struct CronExpression: Equatable, Sendable {
    let minute: FieldSet
    let hour: FieldSet
    let dayOfMonth: FieldSet
    let month: FieldSet
    let dayOfWeek: FieldSet

    /// Set of permitted integer values for one cron field.
    struct FieldSet: Equatable, Sendable {
        let values: Set<Int>
        /// `true` when the source token was a bare `*` — used by the
        /// dom/dow OR-semantics resolver.
        let isWildcard: Bool

        func matches(_ value: Int) -> Bool {
            values.contains(value)
        }
    }

    /// Returns true when `date` falls in the same minute as a scheduled
    /// occurrence in the supplied time zone. Sub-minute resolution is
    /// thrown away — the scheduler ticks per-minute and asks "does THIS
    /// minute match" once per (user, skill).
    func matches(_ date: Date, in timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.minute, .hour, .day, .month, .weekday],
            from: date
        )
        guard
            let minuteValue = components.minute,
            let hourValue = components.hour,
            let dayValue = components.day,
            let monthValue = components.month,
            let weekdayValue = components.weekday
        else {
            return false
        }
        // Calendar.weekday is 1–7 (1 = Sunday); cron dow is 0–6 (0 = Sunday).
        let dowValue = weekdayValue - 1
        guard
            minute.matches(minuteValue),
            hour.matches(hourValue),
            month.matches(monthValue)
        else { return false }

        // dom/dow OR-semantics — both wildcard → match; otherwise match if
        // EITHER restricted field matches.
        if dayOfMonth.isWildcard, dayOfWeek.isWildcard { return true }
        if dayOfMonth.isWildcard { return dayOfWeek.matches(dowValue) }
        if dayOfWeek.isWildcard { return dayOfMonth.matches(dayValue) }
        return dayOfMonth.matches(dayValue) || dayOfWeek.matches(dowValue)
    }
}

extension CronExpression {
    enum ParseError: Error, Equatable {
        case wrongFieldCount(expected: Int, actual: Int)
        case invalidField(name: String, token: String)
        case outOfRange(name: String, value: Int)
    }

    /// Parse e.g. `"0 7 * * *"`. Whitespace-collapsed; comments not supported.
    init(_ raw: String) throws {
        let tokens = raw
            .trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard tokens.count == 5 else {
            throw ParseError.wrongFieldCount(expected: 5, actual: tokens.count)
        }
        self.minute = try Self.parseField(tokens[0], name: "minute", lo: 0, hi: 59)
        self.hour = try Self.parseField(tokens[1], name: "hour", lo: 0, hi: 23)
        self.dayOfMonth = try Self.parseField(tokens[2], name: "dom", lo: 1, hi: 31)
        self.month = try Self.parseField(tokens[3], name: "mon", lo: 1, hi: 12)
        self.dayOfWeek = try Self.parseField(tokens[4], name: "dow", lo: 0, hi: 6)
    }

    private static func parseField(
        _ raw: String,
        name: String,
        lo: Int,
        hi: Int
    ) throws -> FieldSet {
        if raw == "*" {
            return FieldSet(values: Set(lo ... hi), isWildcard: true)
        }
        var collected = Set<Int>()
        for chunk in raw.split(separator: ",") {
            let chunkStr = String(chunk)
            // step: "*/N" or "lo-hi/N"
            let stepParts = chunkStr.split(separator: "/")
            let body = String(stepParts[0])
            let step: Int
            if stepParts.count == 2 {
                guard let parsed = Int(stepParts[1]), parsed >= 1 else {
                    throw ParseError.invalidField(name: name, token: chunkStr)
                }
                step = parsed
            } else if stepParts.count == 1 {
                step = 1
            } else {
                throw ParseError.invalidField(name: name, token: chunkStr)
            }

            let rangeLo: Int
            let rangeHi: Int
            if body == "*" {
                rangeLo = lo
                rangeHi = hi
            } else if body.contains("-") {
                let parts = body.split(separator: "-")
                guard
                    parts.count == 2,
                    let from = Int(parts[0]),
                    let to = Int(parts[1])
                else {
                    throw ParseError.invalidField(name: name, token: chunkStr)
                }
                guard (lo ... hi).contains(from), (lo ... hi).contains(to), from <= to else {
                    throw ParseError.outOfRange(name: name, value: from)
                }
                rangeLo = from
                rangeHi = to
            } else {
                guard let value = Int(body) else {
                    throw ParseError.invalidField(name: name, token: chunkStr)
                }
                guard (lo ... hi).contains(value) else {
                    throw ParseError.outOfRange(name: name, value: value)
                }
                rangeLo = value
                rangeHi = value
            }
            for value in stride(from: rangeLo, through: rangeHi, by: step) {
                collected.insert(value)
            }
        }
        return FieldSet(values: collected, isWildcard: false)
    }
}
