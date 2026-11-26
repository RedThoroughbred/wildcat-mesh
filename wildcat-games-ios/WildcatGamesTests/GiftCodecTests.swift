import XCTest
@testable import WildcatGames

final class GiftCodecTests: XCTestCase {
    private let spot = LatLon(lat: 39.1031, lon: -84.512)

    private func make(_ precision: Gift.Precision = .tight, message: String = "Look under the bench. Happy birthday!") throws -> Gift {
        Gift(id: 0xC0FFEE, precision: precision, hintCenter: GiftCodec.hint(for: spot, radius: 1000), hintRadius: 1000,
             created: Date(timeIntervalSince1970: 1_790_000_000), teaser: "Where we met",
             sealed: try GiftCodec.seal(message, at: spot, id: 0xC0FFEE, precision: precision))
    }

    func testOpensOnTheSpotAndNearby() throws {
        let g = try make()
        XCTAssertEqual(GiftCodec.open(g, at: spot), "Look under the bench. Happy birthday!")
        XCTAssertNotNil(GiftCodec.open(g, at: Geo.offset(spot, distance: 20, bearing: 45)))
    }

    func testStaysLockedAwayFromTheSpot() throws {
        let g = try make()
        XCTAssertNil(GiftCodec.open(g, at: Geo.offset(spot, distance: 150, bearing: 0)))
        XCTAssertNil(GiftCodec.open(g, at: Geo.offset(spot, distance: 400, bearing: 200)))
        let loose = try make(.loose)
        XCTAssertNotNil(GiftCodec.open(loose, at: Geo.offset(spot, distance: 250, bearing: 90)))
    }

    func testWrongGiftIDDoesNotOpen() throws {
        var g = try make()
        g.id += 1
        XCTAssertNil(GiftCodec.open(g, at: spot))
    }

    func testWireRoundTripFitsOnePacket() throws {
        let g = try make(message: String(repeating: "x", count: GiftCodec.maxMessageBytes))
        let data = GiftCodec.encode(g)
        XCTAssertLessThanOrEqual(data.count, 233, "one Meshtastic packet")
        let back = try XCTUnwrap(GiftCodec.decode(data))
        XCTAssertEqual(back.id, g.id)
        XCTAssertEqual(back.teaser, "Where we met")
        XCTAssertEqual(back.hintRadius, 1000)
        XCTAssertEqual(back.hintCenter.lat, g.hintCenter.lat, accuracy: 1e-5)
        XCTAssertNotNil(GiftCodec.open(back, at: spot))
        XCTAssertNil(GiftCodec.decode(Data("hello".utf8)))
    }

    func testLinksAndReceipts() throws {
        let g = try make()
        let link = GiftCodec.link(g)
        XCTAssertTrue(link.hasPrefix("wildcat://gift/"))
        XCTAssertEqual(GiftCodec.gift(fromLink: "Check this out: " + link)?.id, g.id)
        XCTAssertEqual(GiftCodec.receiptID(GiftCodec.openedReceipt(id: 42)), 42)
        XCTAssertNil(GiftCodec.receiptID(GiftCodec.encode(g)))
    }

    func testHintAreaContainsTheSpot() {
        for _ in 0..<50 {
            XCTAssertLessThanOrEqual(Geo.distance(GiftCodec.hint(for: spot, radius: 1000), spot), 600.5)
        }
    }

    func testEncodedSizeIsExact() throws {
        let spot = LatLon(lat: 39.1, lon: -84.5)
        for (msg, teaser) in [("hi", ""), ("Meet me by the old oak at noon", "where we met"), (String(repeating: "x", count: 111), "")] {
            let g = Gift(id: 7, precision: .easy, hintCenter: spot, hintRadius: 300, created: Date(), teaser: teaser,
                         sealed: try GiftCodec.seal(msg, at: spot, id: 7, precision: .easy))
            XCTAssertEqual(GiftCodec.encode(g).count, GiftCodec.encodedSize(message: msg, teaser: teaser))
        }
        XCTAssertEqual(GiftCodec.encodedSize(message: String(repeating: "x", count: 111), teaser: ""), 163, "fits MeshCore exactly")
    }
}
