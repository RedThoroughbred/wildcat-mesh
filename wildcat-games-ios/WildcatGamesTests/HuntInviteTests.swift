import XCTest
import WildcatRadioCore
@testable import WildcatGames

final class HuntInviteTests: XCTestCase {
    func testLinkRoundTripsAndFitsAQRCode() throws {
        let channel = ChannelSettings(name: "WGHUNT", psk: Data(repeating: 9, count: 32)).raw
        let invite = HuntInvite(code: "FOXQ7", channel: channel, fox: NodeNum(0x53FD_8B02), host: NodeNum(0xA038_8880))
        let link = invite.link
        XCTAssertTrue(link.hasPrefix("wildcat://hunt/"))
        XCTAssertFalse(link.contains("+") || link.contains("/") && link.dropFirst(15).contains("/") || link.contains("="))
        XCTAssertLessThan(link.utf8.count, 300, "small enough for a QR code a phone camera reads easily")
        let back = try XCTUnwrap(HuntInvite(link: link))
        XCTAssertEqual(back, invite)
        XCTAssertEqual(back.channelName, "WGHUNT")
        XCTAssertEqual(back.foxNode, NodeNum(0x53FD_8B02))
    }

    func testTheTimeLimitTravelsInTheLinkAndOldLinksStillWork() throws {
        let channel = ChannelSettings(name: "WGHUNT", psk: Data(repeating: 9, count: 32)).raw
        let timed = HuntInvite(code: "FOXQ7", channel: channel, fox: NodeNum(0x53FD_8B02), host: NodeNum(0xA038_8880), limitMinutes: 45)
        XCTAssertLessThan(timed.link.utf8.count, 300)
        let back = try XCTUnwrap(HuntInvite(link: timed.link))
        XCTAssertEqual(back.limitMinutes, 45)
        XCTAssertEqual(back.timeLimit, 2700)
        // A link from before time limits (no limitMinutes key) still opens, with no limit.
        let old = #"{"code":"FOX7","channel":"CgZXR0hVTlQ=","fox":1409125122,"host":2688059520}"#
        let oldLink = "wildcat://hunt/" + Data(old.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let o = try XCTUnwrap(HuntInvite(link: oldLink))
        XCTAssertNil(o.limitMinutes)
        XCTAssertNil(o.timeLimit)
        // Nonsense from a hand-made link is no limit.
        for bad in [0, -5, 100_000] {
            XCTAssertNil(HuntInvite(code: "FOX7", channel: channel, fox: NodeNum(1), host: NodeNum(2), limitMinutes: bad).timeLimit)
        }
    }

    func testRejectsOtherLinks() {
        XCTAssertNil(HuntInvite(link: "wildcat://gift/abc"))
        XCTAssertNil(HuntInvite(link: "wildcat://hunt/not-base64!!"))
        XCTAssertNil(HuntInvite(link: "https://meshtastic.org/e/#abc"))
    }
}
