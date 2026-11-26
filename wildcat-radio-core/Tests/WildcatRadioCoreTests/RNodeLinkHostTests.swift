#if canImport(CoreBluetooth)
import CoreBluetooth
import XCTest
@testable import WildcatRadioCore

/// Host mode: the Reticulum stack on the phone drives the RNode through the link. Its bytes go to
/// the RNode in Bluetooth-sized writes, everything the RNode says goes back to it untouched, the
/// console's own commands stop, and the session keeps decoding the stream for the console.
@MainActor
final class RNodeLinkHostTests: XCTestCase {
    var now = Date(timeIntervalSince1970: 1_791_500_000)
    var written: [Data] = []

    func bytes(_ hex: String) -> Data { Data(hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }) }

    /// A link through its startup conversation (the WisBlock's answers), ready.
    func readyLink() -> RNodeLink {
        let l = RNodeLink(defaults: UserDefaults(suiteName: "wildcat-test-\(UUID().uuidString)")!)
        l.clock = { [unowned self] in self.now }
        l.wire = { [unowned self] in self.written.append($0) }
        l.startSession()
        let replies: [(RNode.Command, String)] = [
            (.detect, "c0 08 46 c0"), (.firmwareVersion, "c0 50 01 56 c0"), (.platform, "c0 48 70 c0"), (.mcu, "c0 49 71 c0"),
            (.board, "c0 47 51 c0"), (.readEEPROM, ""), (.getFrequency, "c0 01 36 87 e2 78 c0"), (.getBandwidth, "c0 02 00 01 e8 48 c0"),
            (.getTxPower, "c0 03 07 c0"), (.getSpreadingFactor, "c0 04 08 c0"), (.getCodingRate, "c0 05 05 c0"), (.getRadioState, "c0 06 00 c0"),
        ]
        for (command, reply) in replies {
            let answer = command == .readEEPROM
                ? bytes(RNodeTests.fixture.exchanges.first { $0.name == "rom_read" }!.received)
                : bytes(reply)
            l.receive(answer)
        }
        XCTAssertEqual(l.state, .ready("RNode"))
        written = []
        return l
    }

    func testAttachedHostTalksToTheRNodeAndTheConsoleWatches() {
        let l = readyLink()
        var toHost = Data()
        var connected: [Bool] = []
        l.attachHost(onBytes: { toHost.append($0) }, onConnected: { connected.append($0) })
        XCTAssertTrue(l.hostAttached)
        XCTAssertTrue(l.hostConnected)
        XCTAssertEqual(connected, [true], "told at once")

        // Host → RNode: a set-frequency command and a 50-byte data frame, in 20-byte writes.
        l.hostChunk = 20
        let command = bytes("c0 01 36 87 e2 78 c0")
        let frame = Data([0xC0, 0x00]) + Data(repeating: 0x42, count: 46) + Data([0xC0])
        l.hostWrite(command + frame)
        XCTAssertEqual(written.map(\.count), [20, 20, 16])
        XCTAssertEqual(written.reduce(Data(), +), command + frame, "bytes go out as they are, in order")

        // RNode → host: the echo, then a heard packet with its RSSI and SNR, split across notifications.
        let fromRNode = bytes("c0 01 36 87 e2 78 c0 c0 23 39 c0 c0 24 1a c0") + Data([0xC0, 0x00, 0x01, 0x00]) + Data(repeating: 7, count: 18) + Data([0xC0])
        l.receive(fromRNode.prefix(9))
        l.receive(fromRNode.dropFirst(9))
        XCTAssertEqual(toHost, fromRNode, "the host gets every byte, untouched")
        XCTAssertEqual(l.session.heard.first?.size, 20, "the console still decodes the stream")
        XCTAssertEqual(l.session.heard.first?.rssi, -100)

        // The console can't send while the host drives.
        written = []
        l.refreshParameters()
        l.setRadio(on: false)
        XCTAssertTrue(written.isEmpty)

        // Detach: the host is told, and the console reads back what the host left.
        l.detachHost()
        XCTAssertEqual(connected, [true, false])
        XCTAssertFalse(l.hostAttached)
        XCTAssertEqual(written.first, RNode.Command.getFrequency.data, "settings read back one at a time")
        let before = toHost.count
        l.receive(bytes("c0 01 36 87 e2 78 c0"))
        XCTAssertEqual(toHost.count, before, "nothing for a detached host")
    }

    func testHostWaitsForTheLinkAndLosesItWithTheLink() {
        let l = RNodeLink(defaults: UserDefaults(suiteName: "wildcat-test-\(UUID().uuidString)")!)
        l.clock = { [unowned self] in self.now }
        l.wire = { [unowned self] in self.written.append($0) }
        var toHost = Data()
        var connected: [Bool] = []
        l.attachHost(onBytes: { toHost.append($0) }, onConnected: { connected.append($0) })
        XCTAssertEqual(connected, [false], "attached before there is a link")
        XCTAssertFalse(l.hostConnected)
        l.hostWrite(bytes("c0 08 73 c0"))
        XCTAssertTrue(written.isEmpty, "nothing goes out without a link")

        // The link comes up: the console's own startup runs, and only then does the host connect.
        l.startSession()
        XCTAssertEqual(written.first, RNode.Command.detect.data, "the console's startup still runs")
        l.receive(bytes("c0 08 46 c0"))
        XCTAssertTrue(toHost.isEmpty, "startup answers are the console's, not the host's")
        XCTAssertEqual(connected, [false])
    }

    func testDetachWithoutAttachIsHarmless() {
        let l = readyLink()
        l.detachHost()
        XCTAssertFalse(l.hostAttached)
        XCTAssertTrue(written.isEmpty)
    }
}
#endif
