import XCTest
@testable import WildcatRadioCore

final class FoxTrackerTests: XCTestCase {
    private let fox = NodeNum(0x9E76_6B18)
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func packet(from: NodeNum? = nil, rssi: Int?, snr: Float? = 5, hops: Int = 0, mqtt: Bool = false) -> MeshPacket {
        MeshPacket(from: from ?? fox, to: .broadcast, channel: 1, id: 1, rxTime: nil, rxSNR: snr, rxRSSI: rssi,
                   hopLimit: 3 - hops, hopStart: 3, viaMQTT: mqtt, relayNode: nil, portnum: .position,
                   rawPortnum: 3, text: nil, position: nil, isEncrypted: false)
    }

    func testOnlyDirectPacketsFromTheFoxCount() {
        var t = FoxTracker(fox: fox)
        XCTAssertNil(t.ingest(packet(from: NodeNum(1), rssi: -60), at: t0))
        XCTAssertNil(t.ingest(packet(rssi: -60, hops: 1), at: t0))
        XCTAssertNil(t.ingest(packet(rssi: -60, mqtt: true), at: t0))
        XCTAssertEqual(t.indirectCount, 2)
        XCTAssertNotNil(t.ingest(packet(rssi: -90), at: t0))
        XCTAssertEqual(t.samples.count, 1)
        XCTAssertEqual(t.latest?.score ?? 0, 43.75, accuracy: 0.001)
    }

    func testRelayedPacketsCountWhenAsked() {
        var relayed = MeshPacket(from: NodeNum(0x1234_5678), to: .broadcast, id: 9, rxSNR: 2, rxRSSI: -101,
                                 hopLimit: 2, hopStart: 3, relayNode: 0x18)
        var t = FoxTracker(fox: fox)
        XCTAssertNil(t.ingest(relayed, at: t0), "off by default")
        t.acceptRelayed = true
        XCTAssertEqual(t.ingest(relayed, at: t0)?.rssi, -101)
        XCTAssertEqual(t.relayedCount, 1)
        relayed.relayNode = 0x19
        XCTAssertNil(t.ingest(relayed, at: t0), "someone else relayed it")
        relayed.relayNode = 0x18
        relayed.viaMQTT = true
        XCTAssertNil(t.ingest(relayed, at: t0), "internet, not radio")
    }

    func testTrendAndBest() {
        var t = FoxTracker(fox: fox)
        t.ingest(packet(rssi: -95), at: t0)
        XCTAssertEqual(t.trend, .none)
        t.ingest(packet(rssi: -90), at: t0.addingTimeInterval(10))
        XCTAssertEqual(t.trend, .warmer)
        t.ingest(packet(rssi: -91), at: t0.addingTimeInterval(20))
        XCTAssertEqual(t.trend, .steady)
        t.ingest(packet(rssi: -99), at: t0.addingTimeInterval(30))
        XCTAssertEqual(t.trend, .colder)
        XCTAssertEqual(t.best?.rssi, -90)
    }

    func testReportThrottle() {
        var t = FoxTracker(fox: fox)
        t.ingest(packet(rssi: -95, snr: 4.44), at: t0)
        XCTAssertEqual(t.reportIfDue(hunt: "FOX7", at: t0), .sig(hunt: "FOX7", .init(rssi: -95, snr: 4.4)))
        XCTAssertNil(t.reportIfDue(hunt: "FOX7", at: t0.addingTimeInterval(1)), "nothing new")
        t.ingest(packet(rssi: -94), at: t0.addingTimeInterval(8))
        XCTAssertNil(t.reportIfDue(hunt: "FOX7", at: t0.addingTimeInterval(8)), "small change, too soon")
        t.ingest(packet(rssi: -88), at: t0.addingTimeInterval(9))
        XCTAssertNotNil(t.reportIfDue(hunt: "FOX7", at: t0.addingTimeInterval(9)), "jump of 7 dB")
        t.ingest(packet(rssi: -88), at: t0.addingTimeInterval(40))
        XCTAssertNotNil(t.reportIfDue(hunt: "FOX7", at: t0.addingTimeInterval(40)), "30 s passed")
    }
}
