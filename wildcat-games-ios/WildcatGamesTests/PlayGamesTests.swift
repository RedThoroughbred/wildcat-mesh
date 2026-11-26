import XCTest
@testable import WildcatGames

/// Play's "Who's playing?" (Small Play 2) picks the games that fit.
@MainActor
final class PlayGamesTests: XCTestCase {
    func testWhosPlayingPicksTheGames() {
        XCTAssertEqual(PlayView.games(for: 1), [.daily, .trails, .solo])
        XCTAssertEqual(PlayView.games(for: 2), [.hunt, .prowl, .gifts])
        XCTAssertEqual(PlayView.games(for: 3), [.hunt, .prowl, .trails])
        XCTAssertEqual(PlayView.games(for: 0), PlayView.games(for: 1))
        XCTAssertEqual(PlayView.games(for: 7), PlayView.games(for: 3))
    }
}
