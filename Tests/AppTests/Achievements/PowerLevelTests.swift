@testable import App
import Testing

/// Pure-function tests for the Home dashboard power-level derivation. The
/// `/v1/dashboard/profile` endpoint reuses this exact math, so locking the
/// curve here keeps the contract honest without DB seeding.
@Suite
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
        #expect(PowerLevel.level(forXP: 1) == 2)   // sqrt(1)=1 -> 2
        #expect(PowerLevel.level(forXP: 3) == 2)   // sqrt(3)=1.7 -> 1 -> 2
        #expect(PowerLevel.level(forXP: 4) == 3)   // sqrt(4)=2 -> 3
        #expect(PowerLevel.level(forXP: 99) == 10) // sqrt(99)=9.9 -> 9 -> 10
        #expect(PowerLevel.level(forXP: 100) == 11) // sqrt(100)=10 -> 11
    }
}
