import Foundation

/// Derives the Home dashboard "power level" from weighted activity XP.
/// Pure and deterministic so it can be unit-tested in isolation and shares
/// one definition between the `/v1/dashboard/profile` handler and its test.
///
/// XP weights reward both volume and the things that express a *maturing*
/// second brain — connected, organised, used consistently:
///   memories × 1  +  sessions × 3  +  jobs × 2  +  badges × 10
///   +  graphConnections × 1  +  activeSpaces × 5  +  streakDays × 3
///
/// `graphConnections` is a cheap lineage proxy (memories with a source page),
/// not the full derived graph. `activeSpaces` is the number of Spaces holding
/// content. `streakDays` is the current consecutive-day activity streak.
///
/// Level curve is `floor(sqrt(xp)) + 1` so early levels come fast and later
/// ones slow down. Level is always ≥ 1 (a brand-new account is level 1).
enum PowerLevel {
    static func xp(
        memoriesTotal: Int,
        sessionsCount: Int,
        jobsCount: Int,
        badgesEarned: Int,
        graphConnections: Int = 0,
        activeSpaces: Int = 0,
        streakDays: Int = 0
    ) -> Int {
        (memoriesTotal * 1) + (sessionsCount * 3) + (jobsCount * 2) + (badgesEarned * 10)
            + (graphConnections * 1) + (activeSpaces * 5) + (streakDays * 3)
    }

    static func level(forXP xp: Int) -> Int {
        guard xp > 0 else { return 1 }
        return Int(Double(xp).squareRoot().rounded(.down)) + 1
    }
}
