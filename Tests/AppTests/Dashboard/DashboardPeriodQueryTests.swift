@testable import App
import Foundation
import LuminaVaultShared
import Testing

@Suite("Dashboard period windows")
struct DashboardPeriodQueryTests {
    @Test func `today window is start of day to now`() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let window = DashboardPeriodQuery.window(period: .today, now: now)
        #expect(window.trunc == "hour")
        #expect(window.start == calendar.startOfDay(for: now))
        #expect(window.end == now)
        #expect(window.previousEnd == window.start)
    }

    @Test func `week window covers seven days`() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let window = DashboardPeriodQuery.window(period: .week, now: now)
        let days = calendar.dateComponents([.day], from: window.start, to: calendar.startOfDay(for: now)).day
        #expect(days == 6)
        #expect(window.trunc == "day")
    }

    @Test func `unknown period string defaults to today`() {
        #expect(DashboardPeriodQuery.parsePeriod(nil) == .today)
        #expect(DashboardPeriodQuery.parsePeriod("nope") == .today)
        #expect(DashboardPeriodQuery.parsePeriod("yesterday") == .yesterday)
    }
}
