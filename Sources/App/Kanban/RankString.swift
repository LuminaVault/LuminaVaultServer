import Foundation

/// Lexicographic "between" key generator for ordering columns/cards.
/// Keys are strings over base-36 digits `0-9a-z`. `between(a, b)` returns a key
/// strictly between `a` and `b` (either may be nil for the start/end). Moving an
/// item = compute one key → single-row update.
enum RankString {
    private static let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    private static let base = digits.count          // 36
    private static func val(_ c: Character) -> Int { digits.firstIndex(of: c) ?? 0 }
    private static func chr(_ i: Int) -> Character { digits[max(0, min(base - 1, i))] }

    /// Returns a key strictly between `lo` and `hi` (nil = unbounded start/end).
    static func between(_ lo: String?, _ hi: String?) -> String {
        let a = Array(lo ?? "")
        let b = hi.map(Array.init)
        var result: [Character] = []
        var i = 0
        while true {
            let da = i < a.count ? val(a[i]) : 0
            let db: Int
            if let b {
                db = i < b.count ? val(b[i]) : 0
            } else {
                db = base
            }
            if db - da > 1 {
                result.append(chr((da + db) / 2))
                return String(result)
            }
            // gap too small at this digit: carry the low digit and go deeper
            result.append(chr(da))
            i += 1
            // both strings exhausted but still equal-prefix: append a midpoint digit
            if i >= a.count, (b == nil || i >= b!.count) {
                result.append(chr(base / 2))
                return String(result)
            }
        }
    }
}
