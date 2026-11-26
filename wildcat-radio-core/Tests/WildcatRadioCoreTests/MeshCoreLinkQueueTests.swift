#if canImport(CoreBluetooth)
import XCTest
@testable import WildcatRadioCore

/// The link's command queue over a pretend wire (no Bluetooth, no practice node):
/// what it writes to the node when the node pushes and answers, byte for byte.
@MainActor
final class MeshCoreLinkQueueTests: XCTestCase {
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    var written: [Data] = []

    func link() -> MeshCoreLink {
        let l = MeshCoreLink(defaults: UserDefaults(suiteName: "wildcat-test-\(UUID().uuidString)")!)
        l.clock = { [unowned self] in self.now }
        l.wire = { [unowned self] in self.written.append($0) }
        return l
    }

    func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

    let sync = MeshCore.Command.syncNextMessage.data
    let messagesWaiting = Data([0x83])
    let noMoreMessages = Data([10])
    /// A v3 channel message (0x11) on channel 1, as the node answers a sync with it.
    func message(_ text: String) -> Data {
        Data([0x11, UInt8(bitPattern: Int8(-26)), 0, 0, 1, 3, 0] + le32(UInt32(now.timeIntervalSince1970)) + Array(text.utf8))
    }
    /// A channel datagram (0x1B), the doc's example: channel 1, DATA_TYPE 0xFF57, "WGG".
    let datagram = Data([0x1B, 22, 0, 0, 1, 2, 0x57, 0xFF, 3, 0x57, 0x47, 0x47])
    let battery = Data([12, 0x10, 0x0E] + [12, 0, 0, 0] + [0xE8, 0x03, 0, 0])

    /// Several messages arrived at the node while the phone was away (or busy): one
    /// MESSAGES_WAITING push, then every sync's answer asks for the next message,
    /// until NO_MORE_MESSAGES. The phone must not stop after the first one.
    func testKeepsSyncingUntilNoMoreMessages() {
        let l = link()
        var texts: [String] = []
        l.addListener { if case .message(let c) = $0 { texts.append(c.text) } }

        l.receive(messagesWaiting)
        XCTAssertEqual(written, [sync], "a push when idle: one sync, in flight")
        XCTAssertEqual(l.inflight, .syncNextMessage)
        l.receive(messagesWaiting)
        l.receive(messagesWaiting)
        XCTAssertEqual(written, [sync], "more pushes while a sync is in flight add nothing")
        XCTAssertTrue(l.queue.isEmpty)

        l.receive(message("MAYA: one"))
        XCTAssertEqual(written.count, 2, "the first message answers the sync and asks for the next")
        XCTAssertEqual(l.inflight, .syncNextMessage)
        l.receive(message("MAYA: two"))
        l.receive(message("MAYA: three"))
        XCTAssertEqual(written, Array(repeating: sync, count: 4), "one sync per message, each after the last answer")

        l.receive(noMoreMessages)
        XCTAssertNil(l.inflight)
        XCTAssertTrue(l.queue.isEmpty)
        XCTAssertEqual(written.count, 4, "NO_MORE_MESSAGES ends it")
        XCTAssertEqual(texts, ["MAYA: one", "MAYA: two", "MAYA: three"])
    }

    /// Datagrams queue on the node like messages and are pulled the same way.
    func testKeepsSyncingPastADatagram() {
        let l = link()
        var got: [MeshCoreSession.Event] = []
        l.addListener { got.append($0) }
        l.receive(messagesWaiting)
        l.receive(datagram)
        XCTAssertEqual(written, [sync, sync], "a datagram answers the sync and asks for the next")
        l.receive(message("MAYA: after the datagram"))
        XCTAssertEqual(written.count, 3)
        l.receive(noMoreMessages)
        XCTAssertEqual(written.count, 3)
        XCTAssertEqual(got.count, 2)
        guard case .datagram(let ch, let dt, let payload, _) = got[0] else { return XCTFail("\(got[0])") }
        XCTAssertEqual([ch, Int(dt), payload.count], [1, 0xFF57, 3])
    }

    /// Pushes while another command is in flight queue a single sync behind it; the
    /// sync goes out when that command is answered, and still drains the node's queue.
    func testPushesWhileBusyQueueOneSyncAndStillDrain() {
        let l = link()
        l.refreshBattery()
        XCTAssertEqual(l.inflight, .getBatteryAndStorage)
        l.receive(messagesWaiting)
        l.receive(messagesWaiting)
        XCTAssertEqual(l.queue, [.syncNextMessage], "two pushes, one sync queued")
        XCTAssertEqual(written.count, 1)

        l.receive(battery)
        XCTAssertEqual(l.session.batteryMillivolts, 3600)
        XCTAssertEqual(written.count, 2, "the battery answer frees the queue: the sync goes out")
        XCTAssertEqual(l.inflight, .syncNextMessage)
        l.receive(message("DEX: one"))
        l.receive(message("DEX: two"))
        XCTAssertEqual(written.count, 4, "both waiting messages pulled")
        l.receive(noMoreMessages)
        XCTAssertNil(l.inflight)
        XCTAssertTrue(l.queue.isEmpty)
        XCTAssertEqual(written.count, 4)
    }
}
#endif
