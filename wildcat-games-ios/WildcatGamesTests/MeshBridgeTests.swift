import XCTest
@testable import WildcatGames

final class MeshBridgeTests: XCTestCase {
    func testMentions() {
        XCTAssertEqual(MeshBridge.mention("@N0CALL hello there")?.name, "N0CALL")
        XCTAssertEqual(MeshBridge.mention("@N0CALL hello there")?.rest, "hello there")
        XCTAssertNil(MeshBridge.mention("@N0CALL"), "a mention needs a message")
        XCTAssertNil(MeshBridge.mention("hello @N0CALL"))
    }

    func testNameMatching() {
        XCTAssertTrue(MeshBridge.matches("n0call", name: "N0CALL E290 INK"), "first word, any case")
        XCTAssertTrue(MeshBridge.matches("STAY", name: "STAY"))
        XCTAssertFalse(MeshBridge.matches("N0C", name: "N0CALL E290 INK"), "no partial words")
        XCTAssertFalse(MeshBridge.matches("x", name: nil))
    }

    func testBridgedTagsParse() {
        XCTAssertEqual(MeshBridge.parse("[MT] GO: What?")?.sender, "GO")
        XCTAssertEqual(MeshBridge.parse("[MC] N0CALL E290 INK: Howdy")?.network, "MeshCore")
        XCTAssertNil(MeshBridge.parse("plain text"))
    }
}

@MainActor
final class PeopleTests: XCTestCase {
    func testHandlesLineUpAcrossNetworks() {
        XCTAssertEqual(PeopleView.handle("N0CALL E290 INK"), "N0CALL")
        XCTAssertEqual(PeopleView.handle("n0call"), "N0CALL")
        XCTAssertNil(PeopleView.handle("GO"), "too short to be a real handle")
        XCTAssertNil(PeopleView.handle(nil))
    }
}
