@testable import App
import XCTest

final class RankStringTests: XCTestCase {
    func testBetweenNilNilIsMidpoint() {
        let r = RankString.between(nil, nil)
        XCTAssertFalse(r.isEmpty)
    }

    func testBetweenOrdersCorrectly() {
        let a = RankString.between(nil, nil)
        let b = RankString.between(a, nil) // after a
        let mid = RankString.between(a, b) // between a and b
        XCTAssertTrue(a < mid)
        XCTAssertTrue(mid < b)
    }

    func testRepeatedInsertAtFrontStaysOrdered() {
        var first = RankString.between(nil, nil)
        for _ in 0 ..< 50 {
            let next = RankString.between(nil, first)
            XCTAssertTrue(next < first)
            first = next
        }
    }

    func testRepeatedInsertAtEndStaysOrdered() {
        var last = RankString.between(nil, nil)
        for _ in 0 ..< 50 {
            let next = RankString.between(last, nil)
            XCTAssertTrue(last < next)
            last = next
        }
    }

    func testAdjacentKeysGetMidpoint() {
        let a = RankString.between(nil, nil)
        let b = RankString.between(a, nil)
        // many inserts between a and b must stay strictly ordered
        var lo = a, hi = b
        for _ in 0 ..< 30 {
            let mid = RankString.between(lo, hi)
            XCTAssertTrue(lo < mid && mid < hi, "lo=\(lo) mid=\(mid) hi=\(hi)")
            hi = mid
        }
    }
}
