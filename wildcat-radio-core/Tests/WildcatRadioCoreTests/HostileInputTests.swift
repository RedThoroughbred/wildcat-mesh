import XCTest
@testable import WildcatRadioCore

/// Anyone in radio range can send these. None of them may crash the app.
final class HostileInputTests: XCTestCase {
    func testSignalValuesThatCannotBeInts() {
        for bad in ["nan", "inf", "-inf", "1e300", "S nan", "Snan", "Sinf", "S1e300", "999999"] {
            _ = WG.Signal(wire: bad)
            _ = WG.Reply("WG W FOX1 HOT 1 BEST \(bad)")
        }
        XCTAssertNil(WG.Signal(wire: "nan"))
        XCTAssertNil(WG.Signal(wire: "1e300"))
        XCTAssertNil(WG.Signal(wire: "Snan"))
        XCTAssertEqual(WG.Signal(wire: "-88.4")?.rssi, -88)
    }

    func testHugeProtobufLength() {
        let huge = Data([0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
        XCTAssertThrowsError(try Proto.Message(huge))
        let nearMax = Data([0x0A, 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])
        XCTAssertThrowsError(try Proto.Message(nearMax))
        XCTAssertThrowsError(try Proto.Message(Data([0x0A, 0x05, 0x01])))
    }
}
