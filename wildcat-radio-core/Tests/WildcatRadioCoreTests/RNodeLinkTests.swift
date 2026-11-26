#if canImport(CoreBluetooth)
import CoreBluetooth
import XCTest
@testable import WildcatRadioCore

/// The RNode link's command queue over a pretend wire: the startup conversation one command
/// at a time, settings written and read back, and a dropped answer.
@MainActor
final class RNodeLinkTests: XCTestCase {
    var now = Date(timeIntervalSince1970: 1_791_500_000)
    var written: [Data] = []

    func link() -> RNodeLink {
        let l = RNodeLink(defaults: UserDefaults(suiteName: "wildcat-test-\(UUID().uuidString)")!)
        l.clock = { [unowned self] in self.now }
        l.wire = { [unowned self] in self.written.append($0) }
        return l
    }

    func bytes(_ hex: String) -> Data { Data(hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }) }

    func answers(_ name: String) -> Data {
        bytes(RNodeTests.fixture.exchanges.first { $0.name == name }!.received)
    }

    /// Replies to the link's startup, as the WisBlock answered over serial.
    let replies: [(RNode.Command, String)] = [
        (.detect, "c0 08 46 c0"), (.firmwareVersion, "c0 50 01 56 c0"), (.platform, "c0 48 70 c0"), (.mcu, "c0 49 71 c0"),
        (.board, "c0 47 51 c0"), (.readEEPROM, ""), (.getFrequency, "c0 01 36 87 e2 78 c0"), (.getBandwidth, "c0 02 00 01 e8 48 c0"),
        (.getTxPower, "c0 03 07 c0"), (.getSpreadingFactor, "c0 04 08 c0"), (.getCodingRate, "c0 05 05 c0"), (.getRadioState, "c0 06 00 c0"),
    ]

    func testStartupIsOneCommandAtATimeUntilReady() {
        let l = link()
        var events: [RNodeSession.Event] = []
        l.onEvent = { events.append($0) }
        l.startSession()
        XCTAssertEqual(written, [RNode.Command.detect.data], "detect goes first, alone")
        XCTAssertEqual(l.inflight, .detect)
        XCTAssertEqual(l.session.phase, .detecting)
        for (i, (command, reply)) in replies.enumerated() {
            XCTAssertEqual(l.inflight, command, "step \(i)")
            XCTAssertEqual(written.last, command.data)
            l.receive(command == .readEEPROM ? answers("rom_read") : bytes(reply))
        }
        XCTAssertNil(l.inflight)
        XCTAssertTrue(l.queue.isEmpty)
        XCTAssertEqual(written.count, replies.count)
        XCTAssertEqual(l.session.phase, .ready)
        XCTAssertEqual(l.state, .ready("RNode"))
        XCTAssertTrue(events.contains(.detected(true)))
        XCTAssertEqual(events.last, .ready)
        XCTAssertEqual(l.session.device.productLine, "RAK4631 779 - 928 MHz (10:12:51)")
        XCTAssertEqual(l.session.parameters.spreadingFactor, 8)
    }

    func testSettingIsWrittenAndTheEchoIsTheReadBack() {
        let l = link()
        l.startSession()
        for (command, reply) in replies { l.receive(command == .readEEPROM ? answers("rom_read") : bytes(reply)) }
        written = []
        l.setSpreadingFactor(9)
        XCTAssertEqual(written, [bytes("c0 04 09 c0")])
        XCTAssertEqual(l.inflight, .setSpreadingFactor(9))
        l.setTxPower(22)
        XCTAssertEqual(written.count, 1, "one command in flight at a time")
        l.receive(bytes("c0 04 09 c0"))
        XCTAssertEqual(l.session.parameters.spreadingFactor, 9, "the RNode's echo is the new value")
        XCTAssertEqual(written, [bytes("c0 04 09 c0"), bytes("c0 03 16 c0")])
        l.receive(bytes("c0 03 16 c0"))
        XCTAssertEqual(l.session.parameters.txPower, 22)
        XCTAssertNil(l.inflight)
        l.setRadio(on: true)
        XCTAssertEqual(written.last, bytes("c0 06 01 c0"))
        l.receive(bytes("c0 06 01 c0"))
        XCTAssertEqual(l.session.parameters.radioOn, true)
    }

    func testLeaveNeedsNoAnswerAndADroppedAnswerTimesOut() {
        let l = link()
        l.startSession()
        for (command, reply) in replies { l.receive(command == .readEEPROM ? answers("rom_read") : bytes(reply)) }
        written = []
        l.enqueue(.leave)
        l.enqueue(.getFrequency)
        XCTAssertEqual(written, [RNode.Command.leave.data, RNode.Command.getFrequency.data], "leave has no reply, so the next goes at once")
        XCTAssertEqual(l.inflight, .getFrequency)
        l.enqueue(.getBandwidth)
        now += 1
        l.checkTimeout()
        XCTAssertEqual(l.inflight, .getFrequency, "not yet")
        now += 1.5
        l.checkTimeout()
        XCTAssertEqual(l.inflight, .getBandwidth, "gave up on the frequency read, moved on")
        XCTAssertEqual(written.last, RNode.Command.getBandwidth.data)
    }

    func testNoDetectAnswerFails() {
        let l = link()
        l.startSession()
        now += 3
        l.checkTimeout()
        guard case .failed(let why) = l.state else { return XCTFail("\(l.state)") }
        XCTAssertTrue(why.contains("RNode"))
        XCTAssertTrue(l.queue.isEmpty)
    }

    func testSomethingElseAnsweringDetectFails() {
        let l = link()
        l.startSession()
        l.receive(bytes("c0 08 00 c0"))
        guard case .failed(let why) = l.state else { return XCTFail("\(l.state)") }
        XCTAssertTrue(why.contains("not an RNode"))
    }

    func testTellsPairingErrorsFromLinkDrops() {
        XCTAssertTrue(RNodeLink.isPairingError(NSError(domain: CBATTErrorDomain, code: CBATTError.insufficientAuthentication.rawValue)))
        XCTAssertTrue(RNodeLink.isPairingError(NSError(domain: CBATTErrorDomain, code: CBATTError.insufficientEncryption.rawValue)))
        XCTAssertTrue(RNodeLink.isPairingError(NSError(domain: CBErrorDomain, code: CBError.peerRemovedPairingInformation.rawValue)))
        XCTAssertTrue(RNodeLink.isPairingError(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pairing was cancelled"])))
        XCTAssertFalse(RNodeLink.isPairingError(NSError(domain: CBErrorDomain, code: CBError.peripheralDisconnected.rawValue)))
        XCTAssertTrue(RNodeLink.isLinkDrop(NSError(domain: CBErrorDomain, code: CBError.peripheralDisconnected.rawValue)))
        XCTAssertTrue(RNodeLink.isLinkDrop(NSError(domain: CBErrorDomain, code: CBError.connectionTimeout.rawValue)))
        XCTAssertFalse(RNodeLink.isLinkDrop(NSError(domain: CBATTErrorDomain, code: CBATTError.insufficientAuthentication.rawValue)))
    }

    func testStaleBondHelpNamesTheEntryToForget() {
        // The classic case: iOS remembers the board by its old name (a Meshtastic/MeshCore life).
        let old = RNodeLink.staleBondHelp(remembered: "WREF_47a0", advertised: "RNode 4FDD")
        XCTAssertTrue(old.contains("find “WREF_47a0”. That is this board's old name: it calls itself RNode 4FDD now"), old)
        XCTAssertTrue(old.contains("Settings → Bluetooth"))
        XCTAssertTrue(old.contains("Tap the ⓘ beside it, then Forget This Device."), old)
        XCTAssertTrue(old.contains("Leave the other entries alone"), old)
        // Same name both ways: just the one name.
        XCTAssertTrue(RNodeLink.staleBondHelp(remembered: "RNode 4FDD", advertised: "rnode 4fdd").contains("find “RNode 4FDD”. Tap"))
        // Nothing known: still actionable.
        XCTAssertTrue(RNodeLink.staleBondHelp(remembered: nil, advertised: nil).contains("find this RNode. Tap"))
        XCTAssertTrue(RNodeLink.staleBondHelp(remembered: " ", advertised: "RNode 4FDD").contains("find “RNode 4FDD”. Tap"))
    }

    func testTheNameShownIsTheAdvertisedOneBeforeTheCachedOne() {
        // iOS caches a board's name; after a reflash the cache is the old firmware's name.
        XCTAssertEqual(RNodeLink.displayName(advertised: "RNode 4FDD", stored: "RNode 4FDD", cached: "MeshCore-Old"), "RNode 4FDD")
        XCTAssertEqual(RNodeLink.displayName(advertised: nil, stored: "RNode 4FDD", cached: "MeshCore-Old"), "RNode 4FDD",
                       "reconnecting without a scan: what it advertised last time")
        XCTAssertEqual(RNodeLink.displayName(advertised: nil, stored: nil, cached: "RNode 1F2A"), "RNode 1F2A")
        XCTAssertEqual(RNodeLink.displayName(advertised: " ", stored: "", cached: nil), "RNode")
    }

    func testASetWithNoAnswerIsReadBackOnce() {
        let l = link()
        l.startSession()
        for (command, reply) in replies { l.receive(command == .readEEPROM ? answers("rom_read") : bytes(reply)) }
        written = []
        l.setSpreadingFactor(9)
        now += 2.5
        l.checkTimeout()
        XCTAssertEqual(l.inflight, .getSpreadingFactor, "the echo was lost: ask what the RNode has")
        XCTAssertEqual(written, [bytes("c0 04 09 c0"), RNode.Command.getSpreadingFactor.data])
        l.receive(bytes("c0 04 09 c0"))
        XCTAssertEqual(l.session.parameters.spreadingFactor, 9)
        XCTAssertNil(l.inflight)
        // A read that gets no answer is not asked again.
        l.enqueue(.getSpreadingFactor)
        now += 2.5
        l.checkTimeout()
        XCTAssertNil(l.inflight)
    }

    func testSetAllMakesAFreshRNodeReadyToTurnOn() {
        let l = link()
        l.startSession()
        // A freshly booted RNode: nothing set but the coding rate.
        let fresh: [(RNode.Command, String)] = [(.getFrequency, "c0 01 00 00 00 00 c0"), (.getBandwidth, "c0 02 00 00 00 00 c0"),
                                                 (.getTxPower, "c0 03 ff c0"), (.getSpreadingFactor, "c0 04 00 c0")]
        for (command, reply) in replies {
            let unset = fresh.first { $0.0 == command }?.1
            l.receive(command == .readEEPROM ? answers("rom_read") : bytes(unset ?? reply))
        }
        XCTAssertFalse(l.session.parameters.canTurnOn)
        written = []
        l.setAll(frequencyHz: 914_875_000, bandwidthHz: 125_000, txPower: 7, spreadingFactor: 8, codingRate: 5)
        // The pretend RNode echoes each set as the firmware does.
        var answered = 0
        while answered < written.count, answered < 10 {
            l.receive(written[answered])
            answered += 1
        }
        XCTAssertEqual(written.count, 5)
        XCTAssertTrue(l.session.parameters.isComplete)
        XCTAssertEqual(l.session.parameters.frequencyHz, 914_875_000)
        XCTAssertEqual(l.session.parameters.txPower, 7)
    }

    func testStaleBondIsOnlyPeerRemovedPairingInformation() {
        XCTAssertTrue(RNodeLink.isStaleBond(NSError(domain: CBErrorDomain, code: CBError.peerRemovedPairingInformation.rawValue)))
        XCTAssertFalse(RNodeLink.isStaleBond(NSError(domain: CBATTErrorDomain, code: CBATTError.insufficientEncryption.rawValue)))
        XCTAssertFalse(RNodeLink.isStaleBond(nil))
    }

    func testPacketsAndChannelStatsFlowWhileIdle() {
        let l = link()
        var events: [RNodeSession.Event] = []
        l.onEvent = { events.append($0) }
        l.startSession()
        for (command, reply) in replies { l.receive(command == .readEEPROM ? answers("rom_read") : bytes(reply)) }
        events = []
        // One Bluetooth notification carrying RSSI, SNR and a 3-byte packet, then channel stats.
        l.receive(bytes("c0 23 39 c0 c0 24 1a c0 c0 00 01 02 03 c0 c0 25 00 00 00 00 00 00 00 00 39 25 ff c0"))
        XCTAssertEqual(events, [.packet(Data([1, 2, 3])), .channelStats])
        XCTAssertEqual(l.session.signal?.rssi, -100)
        XCTAssertEqual(l.session.signal?.snr, 6.5)
        XCTAssertEqual(l.session.channel?.noiseFloor, -120)
        XCTAssertEqual(l.session.channel?.rssi, -100)
    }
}
#endif
