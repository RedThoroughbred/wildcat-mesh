import XCTest
import WildcatRadioCore
@testable import WildcatGames

/// Hashtag keys and the official MeshCore channel link (share and import).
final class MeshCoreChannelCodeTests: XCTestCase {
    func testHashtagKeyMatchesMeshCoreDocs() {
        // companion_protocol.md: "#test" -> 9cd8fcf22a47333b591d96a2b848b73f
        XCTAssertEqual(MeshCoreFormat.hex(MeshCoreChannelCode.hashtagKey("#test")), "9cd8fcf22a47333b591d96a2b848b73f")
        XCTAssertEqual(MeshCoreChannelCode.hashtagKey("#test").count, 16)
        XCTAssertNotEqual(MeshCoreChannelCode.hashtagKey("#Test"), MeshCoreChannelCode.hashtagKey("#test"), "case matters")
        XCTAssertTrue(MeshCoreChannelCode.isHashtag(name: "#test", key: MeshCoreChannelCode.hashtagKey("#test")))
        XCTAssertFalse(MeshCoreChannelCode.isHashtag(name: "#test", key: Data(count: 16)))
        XCTAssertFalse(MeshCoreChannelCode.isHashtag(name: "test", key: MeshCoreChannelCode.hashtagKey("test")))
    }

    func testHashtagNames() {
        XCTAssertEqual(MeshCoreChannelCode.hashtagName("hiking"), "#hiking")
        XCTAssertEqual(MeshCoreChannelCode.hashtagName(" ##hiking "), "#hiking")
        XCTAssertNil(MeshCoreChannelCode.hashtagName("#"))
        XCTAssertNil(MeshCoreChannelCode.hashtagName("two words"))
        XCTAssertEqual(MeshCoreChannelCode.hashtagName(String(repeating: "a", count: 50))?.utf8.count, 31)
    }

    func testOfficialShareLink() {
        let key = MeshCoreChannelCode.publicKey
        XCTAssertEqual(MeshCoreChannelCode(name: "Public", key: key).link,
                       "meshcore://channel/add?name=Public&secret=8b3387e9c5cdea6ac9e5edbaa115cd72")
        let odd = MeshCoreChannelCode(name: "Trail Crew #2 & co", key: key)
        XCTAssertEqual(odd.link, "meshcore://channel/add?name=Trail%20Crew%20%232%20%26%20co&secret=8b3387e9c5cdea6ac9e5edbaa115cd72")
        XCTAssertEqual(MeshCoreChannelCode(scanned: odd.link), odd, "round trip")
        let tag = MeshCoreChannelCode(name: "#test", key: MeshCoreChannelCode.hashtagKey("#test"))
        XCTAssertEqual(MeshCoreChannelCode(scanned: tag.link), tag)
    }

    func testImportAcceptsOfficialAndOlderFormats() {
        let hex = "8b3387e9c5cdea6ac9e5edbaa115cd72"
        // The example straight from MeshCore's qr_codes.md.
        let official = MeshCoreChannelCode(scanned: "meshcore://channel/add?name=Public&secret=\(hex)")
        XCTAssertEqual(official?.name, "Public")
        XCTAssertEqual(official?.key, MeshCoreChannelCode.publicKey)
        // Form-style "+" for spaces, an extra region_scope, and a literal plus as %2B.
        let plus = MeshCoreChannelCode(scanned: "meshcore://channel/add?name=Trail+Crew%2B&secret=\(hex)&region_scope=%23sf")
        XCTAssertEqual(plus?.name, "Trail Crew+")
        // Wildcat's older bare key QR, and keys typed with spaces.
        XCTAssertEqual(MeshCoreChannelCode(scanned: hex)?.key.count, 16)
        XCTAssertNil(MeshCoreChannelCode(scanned: hex)?.name)
        XCTAssertNotNil(MeshCoreChannelCode.key("8b33 87e9 c5cd ea6a c9e5 edba a115 cd72"))
        XCTAssertNil(MeshCoreChannelCode(scanned: "meshcore://channel/add?name=X&secret=1234"))
        XCTAssertNil(MeshCoreChannelCode(scanned: "meshcore://contact/add?name=X&public_key=\(hex)\(hex)&type=1"))
    }
}
