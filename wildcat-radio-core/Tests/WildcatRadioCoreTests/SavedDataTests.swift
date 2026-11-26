import XCTest
@testable import WildcatRadioCore

/// Saved data from an older version must still load in a newer one.
final class SavedDataTests: XCTestCase {
    func testChatWithoutDefaultedFieldsDecodes() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","direction":{"received":{}},"origin":{"channel":{"_0":1}},"text":"hi","at":700000000}"#
        let c = try JSONDecoder().decode(MeshCoreSession.Chat.self, from: Data(old.utf8))
        XCTAssertEqual(c.text, "hi")
        XCTAssertFalse(c.confirmed)
        XCTAssertNil(c.textType)
        XCTAssertEqual(c.origin, .channel(1))
    }

    func testChatRoundTrips() throws {
        var c = MeshCoreSession.Chat(id: UUID(), direction: .sent, origin: .contact(Data([1, 2, 3, 4, 5, 6])), text: "yo", at: Date(timeIntervalSince1970: 1))
        c.confirmed = true
        c.ack = 7
        let back = try JSONDecoder().decode(MeshCoreSession.Chat.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }

    func testHuntCodeInCommands() {
        XCTAssertEqual(FoxReferee.huntCode(in: "WG SIG fox7 -88 6"), "FOX7")
        XCTAssertEqual(FoxReferee.huntCode(in: "WG FOUND FOXAB 1234"), "FOXAB")
        XCTAssertNil(FoxReferee.huntCode(in: "WG FOUND 1234"))
        XCTAssertNil(FoxReferee.huntCode(in: "WG HUNT"))
        XCTAssertNil(FoxReferee.huntCode(in: "hello FOX7"))
    }
}
