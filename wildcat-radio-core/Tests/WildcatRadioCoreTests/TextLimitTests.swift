import XCTest
@testable import WildcatRadioCore

final class TextLimitTests: XCTestCase {
    func testShortTextUnchanged() {
        XCTAssertEqual("hello".utf8Prefix(10), "hello")
        XCTAssertEqual("hello".utf8Prefix(5), "hello")
        XCTAssertEqual("".utf8Prefix(0), "")
    }

    func testCutsWholeCharactersOnly() {
        // "é" is 2 bytes, 🦊 is 4, 👍🏽 is 8 (two scalars, one character).
        XCTAssertEqual("abé".utf8Prefix(3), "ab")
        XCTAssertEqual("ab🦊".utf8Prefix(5), "ab")
        XCTAssertEqual("ab🦊".utf8Prefix(6), "ab🦊")
        XCTAssertEqual("a👍🏽".utf8Prefix(6), "a", "skin tone stays with its thumb")
        for text in ["héllo wörld 🦊🦊🦊", "👩‍👩‍👧‍👦 family", String(repeating: "ñ", count: 200)] {
            for n in 0...60 {
                let cut = text.utf8Prefix(n)
                XCTAssertLessThanOrEqual(cut.utf8.count, n)
                XCTAssertFalse(cut.contains("\u{FFFD}"))
                XCTAssertTrue(text.unicodeScalars.starts(with: cut.unicodeScalars))
            }
        }
    }

    func testOneHugeCharacterFallsBackToScalars() {
        let zalgo = "e" + String(repeating: "\u{0301}", count: 40)   // one character, 81 bytes
        let cut = zalgo.utf8Prefix(10)
        XCTAssertFalse(cut.isEmpty)
        XCTAssertLessThanOrEqual(cut.utf8.count, 10)
        XCTAssertFalse(cut.contains("\u{FFFD}"))
    }

    func testRadioTextKeepsWholeCharacters() {
        let text = WG.Command.found(hunt: "FOX7", code: String(repeating: "🦊", count: 60)).text
        XCTAssertLessThanOrEqual(text.utf8.count, WG.maxBytes)
        XCTAssertFalse(text.contains("\u{FFFD}"))
    }
}
