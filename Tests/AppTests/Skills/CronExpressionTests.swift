@testable import App
import Foundation
import Testing

/// HER-170: pure-function tests for CronExpression. No DB, no clocks —
/// every test pins explicit `Date` + `TimeZone` so semantics are
/// reproducible across machines.
struct CronExpressionTests {
    private static func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
        in tz: TimeZone,
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.date(from: components)!
    }

    private static let lisbon = TimeZone(identifier: "Europe/Lisbon")!
    private static let utc = TimeZone(identifier: "UTC")!

    @Test
    func `parses 5 fields`() throws {
        let expr = try CronExpression("0 7 * * *")
        #expect(expr.minute.values == [0])
        #expect(expr.hour.values == [7])
        #expect(expr.dayOfMonth.isWildcard)
        #expect(expr.month.isWildcard)
        #expect(expr.dayOfWeek.isWildcard)
    }

    @Test
    func `rejects wrong field count`() {
        #expect(throws: (any Error).self) { _ = try CronExpression("0 7 * *") }
        #expect(throws: (any Error).self) { _ = try CronExpression("") }
    }

    @Test
    func `daily 7am Lisbon matches 0700 local`() throws {
        let expr = try CronExpression("0 7 * * *")
        let due = Self.date(2026, 5, 11, 7, 0, in: Self.lisbon)
        let notDue = Self.date(2026, 5, 11, 6, 59, in: Self.lisbon)
        #expect(expr.matches(due, in: Self.lisbon))
        #expect(!expr.matches(notDue, in: Self.lisbon))
    }

    @Test
    func `tz aware 0700 lisbon does not match 0700 utc when offset differs`() throws {
        // May 2026 — Lisbon is in WEST (UTC+1), so 07:00 Lisbon = 06:00 UTC.
        let expr = try CronExpression("0 7 * * *")
        let lisbonInstant = Self.date(2026, 5, 11, 7, 0, in: Self.lisbon)
        // The same instant evaluated against UTC clock is 06:00 — does NOT match.
        #expect(expr.matches(lisbonInstant, in: Self.lisbon))
        #expect(!expr.matches(lisbonInstant, in: Self.utc))
    }

    @Test
    func `step expression every 15 minutes`() throws {
        let expr = try CronExpression("*/15 * * * *")
        for minute in [0, 15, 30, 45] {
            #expect(expr.matches(Self.date(2026, 5, 11, 7, minute, in: Self.utc), in: Self.utc))
        }
        for minute in [1, 14, 16, 29] {
            #expect(!expr.matches(Self.date(2026, 5, 11, 7, minute, in: Self.utc), in: Self.utc))
        }
    }

    @Test
    func `range expression office hours`() throws {
        let expr = try CronExpression("0 9-17 * * *")
        #expect(expr.matches(Self.date(2026, 5, 11, 9, 0, in: Self.utc), in: Self.utc))
        #expect(expr.matches(Self.date(2026, 5, 11, 12, 0, in: Self.utc), in: Self.utc))
        #expect(expr.matches(Self.date(2026, 5, 11, 17, 0, in: Self.utc), in: Self.utc))
        #expect(!expr.matches(Self.date(2026, 5, 11, 8, 0, in: Self.utc), in: Self.utc))
        #expect(!expr.matches(Self.date(2026, 5, 11, 18, 0, in: Self.utc), in: Self.utc))
    }

    @Test
    func `dow only weekly memo monday 9am`() throws {
        let expr = try CronExpression("0 9 * * 1")
        // 2026-05-11 is a Monday.
        let monday = Self.date(2026, 5, 11, 9, 0, in: Self.utc)
        let tuesday = Self.date(2026, 5, 12, 9, 0, in: Self.utc)
        #expect(expr.matches(monday, in: Self.utc))
        #expect(!expr.matches(tuesday, in: Self.utc))
    }

    @Test
    func `dom or dow semantics`() throws {
        // POSIX: dom OR dow when both restricted. So `0 0 1 * 1` fires on
        // EVERY 1st AND every Monday — not just 1st-falling-on-Monday.
        let expr = try CronExpression("0 0 1 * 1")
        let firstOfJune = Self.date(2026, 6, 1, 0, 0, in: Self.utc) // Monday
        let firstOfJuly = Self.date(2026, 7, 1, 0, 0, in: Self.utc) // Wednesday — dom matches
        let randomMonday = Self.date(2026, 5, 11, 0, 0, in: Self.utc) // Monday — dow matches
        let randomTuesday = Self.date(2026, 5, 12, 0, 0, in: Self.utc) // Neither
        #expect(expr.matches(firstOfJune, in: Self.utc))
        #expect(expr.matches(firstOfJuly, in: Self.utc))
        #expect(expr.matches(randomMonday, in: Self.utc))
        #expect(!expr.matches(randomTuesday, in: Self.utc))
    }

    @Test
    func `comma list of minutes`() throws {
        let expr = try CronExpression("0,30 * * * *")
        #expect(expr.matches(Self.date(2026, 5, 11, 8, 0, in: Self.utc), in: Self.utc))
        #expect(expr.matches(Self.date(2026, 5, 11, 8, 30, in: Self.utc), in: Self.utc))
        #expect(!expr.matches(Self.date(2026, 5, 11, 8, 15, in: Self.utc), in: Self.utc))
    }

    @Test
    func `out of range integer rejected`() {
        #expect(throws: (any Error).self) { _ = try CronExpression("60 7 * * *") }
        #expect(throws: (any Error).self) { _ = try CronExpression("0 24 * * *") }
        #expect(throws: (any Error).self) { _ = try CronExpression("0 7 0 * *") } // dom min is 1
        #expect(throws: (any Error).self) { _ = try CronExpression("0 7 * * 7") } // dow max is 6
    }
}
