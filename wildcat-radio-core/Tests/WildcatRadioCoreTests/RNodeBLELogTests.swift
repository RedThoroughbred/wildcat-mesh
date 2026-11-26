#if canImport(CoreBluetooth)
import CoreBluetooth
import XCTest
@testable import WildcatRadioCore

/// The RNode Bluetooth diary: a header per session, timestamped lines, the tail kept when it
/// grows, nothing written when it's off, and CoreBluetooth errors spelled out.
final class RNodeBLELogTests: XCTestCase {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rnode-ble-log-test-\(UUID().uuidString)").appendingPathComponent("rnode-ble.log")
    }

    func testHeaderThenTimestampedLinesInOrder() {
        let url = tempURL()
        let log = RNodeBLELog(url: url, enabled: true)
        log.beginSession()
        log.beginSession()
        log.log("central state: poweredOn(5)")
        log.log("didConnect RNode 1F2A")
        let text = log.tail()
        XCTAssertEqual(text.components(separatedBy: "==== RNode BLE log: session").count, 2, "one header per process")
        XCTAssertTrue(text.contains("os: "))
        XCTAssertTrue(text.contains("bluetooth authorization: "))
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.suffix(2).map { String($0.dropFirst(25)) }, ["central state: poweredOn(5)", "didConnect RNode 1F2A"])
        XCTAssertTrue(lines.last!.hasPrefix("20"), "each line starts with the date: \(lines.last!)")
        XCTAssertEqual(String(lines.last!.prefix(23)).count, 23)
        XCTAssertEqual(try Data(contentsOf: url).count, text.utf8.count)
    }

    func testKeepsOnlyTheTailWhenItGrows() throws {
        let url = tempURL()
        let log = RNodeBLELog(url: url, enabled: true)
        let line = String(repeating: "x", count: 1000)
        // ~1 KB a line: crosses the 256 KB trim point once, then a few more lines.
        for i in 0..<260 { log.log("\(i) \(line)") }
        let text = log.tail(bytes: 1 << 20)
        let size = try Data(contentsOf: url).count
        XCTAssertLessThanOrEqual(size, RNodeBLELog.keepBytes + 8000, "trimmed back to about keepBytes")
        XCTAssertGreaterThan(size, RNodeBLELog.keepBytes - 2000, "the tail survived")
        XCTAssertTrue(text.hasPrefix("---- older lines trimmed ----\n"))
        XCTAssertTrue(text.hasSuffix("259 \(line)\n"), "the newest line is last")
        XCTAssertFalse(text.contains("  0 \(line)"), "the oldest line is gone")
        let second = text.split(separator: "\n")[1]
        XCTAssertTrue(second.hasPrefix("20"), "the cut lands on a line boundary: \(second.prefix(40))")
    }

    func testOffWritesNothing() {
        let url = tempURL()
        let log = RNodeBLELog(url: url, enabled: false)
        log.beginSession()
        log.log("nothing")
        XCTAssertFalse(log.isEnabled)
        XCTAssertNil(log.url)
        XCTAssertEqual(log.tail(), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(RNodeBLELog(url: nil, enabled: true).isEnabled)
    }

    func testClearStartsOver() {
        let url = tempURL()
        let log = RNodeBLELog(url: url, enabled: true)
        log.beginSession()
        log.log("one")
        log.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        log.beginSession()
        log.log("two")
        let text = log.tail()
        XCTAssertTrue(text.contains("==== RNode BLE log"), "a new header after clearing")
        XCTAssertFalse(text.contains("one"))
        XCTAssertTrue(text.hasSuffix("two\n"))
    }

    func testCoreBluetoothErrorsAreSpelledOut() {
        let peer = NSError(domain: CBErrorDomain, code: CBError.peerRemovedPairingInformation.rawValue,
                           userInfo: [NSLocalizedDescriptionKey: "Peer removed pairing information"])
        let s = RNodeBLELog.describe(peer)
        XCTAssertTrue(s.contains("CBErrorDomain code=14 (peerRemovedPairingInformation)"), s)
        XCTAssertTrue(s.contains("\"Peer removed pairing information\""), s)
        XCTAssertTrue(s.contains("userInfo={NSLocalizedDescription: Peer removed pairing information}"), s)
        let att = RNodeBLELog.describe(NSError(domain: CBATTErrorDomain, code: CBATTError.insufficientEncryption.rawValue))
        XCTAssertTrue(att.contains("CBATTErrorDomain code=15 (insufficientEncryption)"), att)
        XCTAssertEqual(RNodeBLELog.describe(nil), "nil")
        XCTAssertTrue(RNodeBLELog.describe(NSError(domain: "x", code: 99)).hasPrefix("x code=99 \""))
        XCTAssertEqual(RNodeBLELog.name(CBManagerState.poweredOn), "poweredOn(5)")
        XCTAssertEqual(RNodeBLELog.name(CBManagerAuthorization.allowedAlways), "allowedAlways(3)")
        XCTAssertEqual(RNodeBLELog.name(CBPeripheralState.connecting), "connecting(1)")
        XCTAssertEqual(RNodeBLELog.describe([.write, .notify] as CBCharacteristicProperties), "0x18[write,notify]")
        XCTAssertEqual(RNodeBLELog.describe(advertisement: [
            CBAdvertisementDataLocalNameKey: "RNode 1F2A",
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: RNode.service)],
            CBAdvertisementDataIsConnectable: NSNumber(value: true),
        ]), "localName=\"RNode 1F2A\" services=[6E400001-B5A3-F393-E0A9-E50E24DCCA9E] isConnectable=true")
    }

    @MainActor func testLinkWritesItsOwnTransitions() {
        let url = tempURL()
        let log = RNodeBLELog(url: url, enabled: true)
        let l = RNodeLink(defaults: UserDefaults(suiteName: "wildcat-test-\(UUID().uuidString)")!, log: log)
        l.wire = { _ in }
        l.startSession()
        l.receive(Data([0xC0, 0x08, 0x00, 0xC0]))
        let text = log.tail()
        XCTAssertTrue(text.contains("link init:"), text)
        XCTAssertTrue(text.contains("startSession:"), text)
        XCTAssertTrue(text.contains("note: → detect"), text)
        XCTAssertTrue(text.contains("fail: \"That's not an RNode"), text)
        XCTAssertTrue(text.contains("reset: state idle → failed("), text)
    }
}
#endif
