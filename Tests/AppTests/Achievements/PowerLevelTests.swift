@testable import App
import Testing

/// Pure-function tests for the Home dashboard power-level derivation. The
/// `/v1/dashboard/profile` endpoint reuses this exact math, so locking the
/// curve here keeps the contract honest without DB seeding.
struct PowerLevelTests {
    @Test
    func `xp weights memories, sessions, jobs, and badges`() {
        // 10*1 + 4*3 + 5*2 + 2*10 = 10 + 12 + 10 + 20 = 52
        let xp = PowerLevel.xp(memoriesTotal: 10, sessionsCount: 4, jobsCount: 5, badgesEarned: 2)
        #expect(xp == 52)
    }

    @Test
    func `level is at least one for zero xp`() {
        #expect(PowerLevel.level(forXP: 0) == 1)
        #expect(PowerLevel.level(forXP: -5) == 1)
    }

    @Test
    func `level follows floor sqrt plus one`() {
        #expect(PowerLevel.level(forXP: 1) == 2) // sqrt(1)=1 -> 2
        #expect(PowerLevel.level(forXP: 3) == 2) // sqrt(3)=1.7 -> 1 -> 2
        #expect(PowerLevel.level(forXP: 4) == 3) // sqrt(4)=2 -> 3
        #expect(PowerLevel.level(forXP: 99) == 10) // sqrt(99)=9.9 -> 9 -> 10
        #expect(PowerLevel.level(forXP: 100) == 11) // sqrt(100)=10 -> 11
    }

    @Test
    func `xp adds connections, spaces, and streak`() {
        // base 52 + connections 7*1 + spaces 3*5 + streak 4*3 = 52+7+15+12 = 86
        let xp = PowerLevel.xp(
            memoriesTotal: 10, sessionsCount: 4, jobsCount: 5, badgesEarned: 2,
            graphConnections: 7, activeSpaces: 3, streakDays: 4,
        )
        #expect(xp == 86)
    }

    @Test
    func `new xp terms default to zero for the legacy call shape`() {
        let legacy = PowerLevel.xp(memoriesTotal: 10, sessionsCount: 4, jobsCount: 5, badgesEarned: 2)
        let explicit = PowerLevel.xp(
            memoriesTotal: 10, sessionsCount: 4, jobsCount: 5, badgesEarned: 2,
            graphConnections: 0, activeSpaces: 0, streakDays: 0,
        )
        #expect(legacy == 52)
        #expect(legacy == explicit)
    }

    @Test
    func `streak counts the most recent unbroken run`() {
        // Most recent run: 05,04,03 (3 days). 01 is older with a gap at 02.
        let keys = ["2026-06-01", "2026-06-03", "2026-06-04", "2026-06-05"]
        #expect(DashboardController.consecutiveStreak(fromDayKeys: keys) == 3)
    }

    @Test
    func `streak is order-independent and dedupes`() {
        let keys = ["2026-06-05", "2026-06-04", "2026-06-04", "2026-06-03"]
        #expect(DashboardController.consecutiveStreak(fromDayKeys: keys) == 3)
    }

    @Test
    func `streak is zero with no activity and one for a single day`() {
        #expect(DashboardController.consecutiveStreak(fromDayKeys: []) == 0)
        #expect(DashboardController.consecutiveStreak(fromDayKeys: ["2026-06-05"]) == 1)
    }

    @Test
    func `streak spans month boundaries`() {
        // Jan 31 → Feb 1 → Feb 2 is a 3-day run across the month edge.
        let keys = ["2026-01-31", "2026-02-01", "2026-02-02"]
        #expect(DashboardController.consecutiveStreak(fromDayKeys: keys) == 3)
    }
}
