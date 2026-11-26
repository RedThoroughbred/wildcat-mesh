import XCTest
@testable import WildcatRadioCore

/// Hashtag channel keys (docs/companion_protocol.md) and the official app's channel
/// link (docs/qr_codes.md), both from meshcore-dev/MeshCore.
final class MeshCoreChannelsTests: XCTestCase {
    func hex(_ d: Data?) -> String? { d?.map { String(format: "%02x", $0) }.joined() }

    func testHashtagKeyMatchesTheDocExample() {
        XCTAssertEqual(hex(MeshCore.hashtagKey("#test")), "9cd8fcf22a47333b591d96a2b848b73f")
        XCTAssertEqual(MeshCore.hashtagKey("#test")?.count, 16)
    }

    func testHashtagKeyNeedsTheHashAndANameAndKeepsCase() {
        XCTAssertNil(MeshCore.hashtagKey("test"))
        XCTAssertNil(MeshCore.hashtagKey("#"))
        XCTAssertNotEqual(MeshCore.hashtagKey("#Test"), MeshCore.hashtagKey("#test"), "hashed exactly as given")
        XCTAssertEqual(MeshCore.hashtagKey("#wildcat")?.count, 16)
    }

    func testHashtagNameTidiesWhatWasTyped() {
        XCTAssertEqual(MeshCore.hashtagName("  test "), "#test")
        XCTAssertEqual(MeshCore.hashtagName("##test"), "#test")
        XCTAssertEqual(MeshCore.hashtagName("#Park Walk"), "#Park Walk")
        XCTAssertNil(MeshCore.hashtagName(" # "))
    }

    func testChannelLinkReadsTheDocExample() throws {
        let l = try XCTUnwrap(MeshCore.ChannelLink(url: "meshcore://channel/add?name=Public&secret=8b3387e9c5cdea6ac9e5edbaa115cd72"))
        XCTAssertEqual(l.name, "Public")
        XCTAssertEqual(hex(l.secret), "8b3387e9c5cdea6ac9e5edbaa115cd72")
        XCTAssertNil(l.regionScope)
        XCTAssertEqual(l.url, "meshcore://channel/add?name=Public&secret=8b3387e9c5cdea6ac9e5edbaa115cd72")
    }

    func testChannelLinkRoundTripsAwkwardNames() throws {
        let secret = Data(0..<16)
        for name in ["Park Walk", "#hunt", "a&b=c", "Café ☕", "plus+sign", ""] {
            let l = MeshCore.ChannelLink(name: name, secret: secret, regionScope: name.isEmpty ? nil : "us-ca")
            XCTAssertFalse(l.url.contains(" "), l.url)
            let back = try XCTUnwrap(MeshCore.ChannelLink(url: l.url), l.url)
            XCTAssertEqual(back, l, l.url)
        }
        XCTAssertEqual(MeshCore.ChannelLink(name: "Park Walk", secret: secret).url,
                       "meshcore://channel/add?name=Park%20Walk&secret=000102030405060708090a0b0c0d0e0f")
    }

    func testChannelLinkAcceptsFormSpacesAndRegionScope() throws {
        let l = try XCTUnwrap(MeshCore.ChannelLink(
            url: " meshcore://channel/add?name=Park+Walk&secret=8B3387E9C5CDEA6AC9E5EDBAA115CD72&region_scope=us%2Dca \n"))
        XCTAssertEqual(l.name, "Park Walk")
        XCTAssertEqual(hex(l.secret), "8b3387e9c5cdea6ac9e5edbaa115cd72")
        XCTAssertEqual(l.regionScope, "us-ca")
    }

    func testChannelLinkRejectsAnythingElse() {
        for s in ["", "meshcore://contact/add?name=x&public_key=00", "https://example.com/?secret=8b3387e9c5cdea6ac9e5edbaa115cd72",
                  "meshcore://channel/add?name=x", "meshcore://channel/add?name=x&secret=8b33",
                  "meshcore://channel/add?name=x&secret=zz3387e9c5cdea6ac9e5edbaa115cd72",
                  "meshcore://channel/add?name=%ZZ&secret=", String(repeating: "a", count: 5000)] {
            XCTAssertNil(MeshCore.ChannelLink(url: s), s)
        }
    }
}
