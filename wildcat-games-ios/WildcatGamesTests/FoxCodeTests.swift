import XCTest
@testable import WildcatGames

/// The code the host form starts with: four digits, never an obvious one.
final class FoxCodeTests: XCTestCase {
    func testTrivialFoxCodes() {
        for c in ["0000", "1111", "9999", "1234", "0123", "6789", "4321", "3210", "9876"] {
            XCTAssertTrue(FoxCode.isTrivial(c), c)
        }
        for c in ["4417", "1235", "1212", "0001", "9870", "4821", "2468"] {
            XCTAssertFalse(FoxCode.isTrivial(c), c)
        }
    }

    func testRandomFoxCodesAreFourDigitsAndNeverTrivial() {
        var g = SeededGenerator(seed: 7)
        var seen = Set<String>()
        for _ in 0..<5000 {
            let c = FoxCode.random(using: &g)
            XCTAssertEqual(c.count, 4)
            XCTAssertTrue(c.allSatisfy { $0.isASCII && $0.isNumber }, c)
            XCTAssertFalse(FoxCode.isTrivial(c), c)
            seen.insert(c)
        }
        XCTAssertGreaterThan(seen.count, 3000, "spread over the whole range")
        XCTAssertEqual(FoxCode.random().count, 4)
    }
}
