import XCTest
@testable import WildcatGames

final class ReviewPromptTests: XCTestCase {
    private let notTesting: [String: String] = [:]

    func testAsksOncePerVersion() {
        XCTAssertTrue(ReviewPrompt.shouldAsk(lastAsked: "", version: "1.2", busy: false, environment: notTesting),
                      "never asked")
        XCTAssertTrue(ReviewPrompt.shouldAsk(lastAsked: "1.1", version: "1.2", busy: false, environment: notTesting),
                      "asked in an older version")
        XCTAssertFalse(ReviewPrompt.shouldAsk(lastAsked: "1.2", version: "1.2", busy: false, environment: notTesting),
                       "already asked in this version")
    }

    func testNeverWhileBusyWithoutAVersionOrUnderXCTest() {
        XCTAssertFalse(ReviewPrompt.shouldAsk(lastAsked: "", version: "1.2", busy: true, environment: notTesting),
                       "a hunt, hosted hunt or walk is running")
        XCTAssertFalse(ReviewPrompt.shouldAsk(lastAsked: "", version: nil, busy: false, environment: notTesting))
        XCTAssertFalse(ReviewPrompt.shouldAsk(lastAsked: "", version: "", busy: false, environment: notTesting))
        XCTAssertFalse(ReviewPrompt.shouldAsk(lastAsked: "", version: "1.2", busy: false),
                       "this very test run is an XCTest host")
    }

    func testHuntingUntilTheFoxIsFound() {
        XCTAssertTrue(ReviewPrompt.isHunting(.joining))
        XCTAssertTrue(ReviewPrompt.isHunting(.hunting))
        XCTAssertFalse(ReviewPrompt.isHunting(.found(place: 1, points: 100, proofs: [], minutes: 12)),
                       "the find is the moment to ask")
        XCTAssertFalse(ReviewPrompt.isHunting(.ended(winner: "MAYA", found: 2, total: 3)))
        XCTAssertFalse(ReviewPrompt.isHunting(.idle))
    }
}
