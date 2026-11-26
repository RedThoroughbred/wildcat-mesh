import XCTest
@testable import WildcatGames

final class PacketFeedTests: XCTestCase {
    @MainActor func testMeshCoreShortAdvert() {
        // header: flood route (1), advert type (4 << 2); one 1-byte hop (0xAB); a payload too short to be an advert.
        let e = PacketFeed.meshcore(Data([0x11, 0x01, 0xAB, 0x00, 0x00]), snr: -3.25)
        XCTAssertEqual(e?.network, .meshcore)
        XCTAssertEqual(e?.kind, "ADVERT")
        XCTAssertEqual(e?.text, "−3.2dB 1h")
    }

    @MainActor func testMeshCoreGarbageIsIgnored() {
        XCTAssertNil(PacketFeed.meshcore(Data([0x11]), snr: 0))
    }
}
