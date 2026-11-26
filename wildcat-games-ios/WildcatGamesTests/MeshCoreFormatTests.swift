import XCTest
import WildcatRadioCore
@testable import WildcatGames

final class MeshCoreFormatTests: XCTestCase {
    private func contact(_ b: UInt8, _ kind: MeshCore.Contact.Kind = .chat, name: String = "", hops: Int? = nil,
                         path: [UInt8] = [], heard: Date? = nil) -> MeshCore.Contact {
        var c = MeshCore.Contact(publicKey: Data([b] + [UInt8](repeating: 7, count: 31)), kind: kind, flags: 0,
                                 pathLength: hops, name: name, lastAdvert: heard, position: nil, lastModified: nil)
        c.path = Data(path)
        return c
    }

    func testBatteryPercent() {
        XCTAssertEqual(MeshCoreFormat.batteryPercent(millivolts: 4200), 100)
        XCTAssertEqual(MeshCoreFormat.batteryPercent(millivolts: 3300), 0)
        XCTAssertEqual(MeshCoreFormat.batteryPercent(millivolts: 3750), 50)
        XCTAssertEqual(MeshCoreFormat.batteryPercent(millivolts: 4500), 100)
        XCTAssertNil(MeshCoreFormat.batteryPercent(millivolts: 0))
    }

    func testHopsAndMinus() {
        XCTAssertEqual(MeshCoreFormat.hops(0), "direct")
        XCTAssertEqual(MeshCoreFormat.hops(1), "1 hop")
        XCTAssertEqual(MeshCoreFormat.hops(3), "3 hops")
        XCTAssertEqual(MeshCoreFormat.db(-3.25), "−3.25 dB")
        XCTAssertEqual(MeshCoreFormat.number(.nan), "—")
    }

    func testAgo() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(MeshCoreFormat.ago(now, now: now), "just now")
        XCTAssertEqual(MeshCoreFormat.ago(now, now: now, short: true), "now")
        XCTAssertEqual(MeshCoreFormat.ago(now.addingTimeInterval(-42), now: now), "42 s ago")
        XCTAssertEqual(MeshCoreFormat.ago(now.addingTimeInterval(-600), now: now, short: true), "10 min")
        XCTAssertEqual(MeshCoreFormat.ago(now.addingTimeInterval(-7200), now: now), "2 h ago")
        // A clock in the future never goes negative.
        XCTAssertEqual(MeshCoreFormat.ago(now.addingTimeInterval(60), now: now), "just now")
    }

    func testRingsReachPastTheFarthestNode() {
        XCTAssertEqual(MeshCoreFormat.rings(farthest: 0), [250, 500, 750])
        XCTAssertEqual(MeshCoreFormat.rings(farthest: 1200), [500, 1000, 1500])
        XCTAssertEqual(MeshCoreFormat.rings(farthest: 1_000_000), [50_000, 100_000, 150_000])
    }

    func testPathHashes() {
        XCTAssertEqual(MeshCoreFormat.pathHashes(contact(1, hops: 2, path: [0xa4, 0xc4])), [Data([0xa4]), Data([0xc4])])
        XCTAssertEqual(MeshCoreFormat.pathHashes(contact(1, hops: 0, path: [])), [])
        // A path shorter than its length claims doesn't trap.
        XCTAssertEqual(MeshCoreFormat.pathHashes(contact(1, hops: 3, path: [0xa4])), [Data([0xa4])])
        XCTAssertEqual(MeshCoreFormat.pathHashes(contact(1, hops: nil, path: [0xa4])), [])
    }

    func testSortBySignalThenName() {
        let a = contact(1, name: "Bravo"), b = contact(2, name: "alpha"), c = contact(3, name: "Charlie")
        let snr: [UInt8: Double] = [1: 4, 3: 9]
        let sorted = MeshCoreFormat.sorted([a, b, c], by: .signal) { key in
            snr[key[0]].map { PacketFeed.NodeSignal(snr: $0, rssi: nil, hops: 0, at: Date()) }
        }
        XCTAssertEqual(sorted.map(\.name), ["Charlie", "Bravo", "alpha"])
        XCTAssertEqual(MeshCoreFormat.sorted([a, b, c], by: .name) { _ in nil }.map(\.name), ["alpha", "Bravo", "Charlie"])
    }

    func testHeardRecently() {
        let now = Date()
        let fresh = contact(1, heard: now.addingTimeInterval(-60))
        let old = contact(2, heard: now.addingTimeInterval(-3 * 86_400))
        let never = contact(3)
        XCTAssertEqual(MeshCoreFormat.heardRecently([fresh, old, never], now: now).map(\.publicKey), [fresh.publicKey])
    }

    func testSummarySentence() {
        let full = { (p: (lead: String, bold: String, rest: String)) in p.lead + p.bold + p.rest }
        XCTAssertEqual(full(MeshCoreFormat.summary(heard: 7, repeaters: 2, batteryMillivolts: 4000)),
                       "All good. Hearing 7 nodes, 2 of them repeaters.")
        XCTAssertEqual(full(MeshCoreFormat.summary(heard: 1, repeaters: 1, batteryMillivolts: nil)),
                       "All good. Hearing 1 node, a repeater.")
        XCTAssertTrue(full(MeshCoreFormat.summary(heard: 0, repeaters: 0, batteryMillivolts: nil)).contains("Nothing heard yet"))
        XCTAssertTrue(full(MeshCoreFormat.summary(heard: 5, repeaters: 0, batteryMillivolts: nil)).contains("no repeaters"))
        XCTAssertTrue(full(MeshCoreFormat.summary(heard: 5, repeaters: 2, batteryMillivolts: 3320)).hasPrefix("Battery low"))
    }

    func testActivityBins() {
        let now = Date(timeIntervalSince1970: 10_000)
        let bins = MeshCoreFormat.activity([now, now.addingTimeInterval(-30), now.addingTimeInterval(-90),
                                            now.addingTimeInterval(-3600), now.addingTimeInterval(5)], now: now, minutes: 3)
        XCTAssertEqual(bins, [0, 1, 2])
    }

    func testPresetName() {
        XCTAssertNotNil(MeshCoreFormat.presetName(frequency: 910.525, bandwidth: 62.5, spreadingFactor: 7, codingRate: 5))
        XCTAssertNil(MeshCoreFormat.presetName(frequency: 915, bandwidth: 250, spreadingFactor: 10, codingRate: 5))
    }

    func testJSONEscapes() {
        let json = MeshCoreFormat.json([KeyValueItem(key: "name", value: "say \"hi\"")])
        XCTAssertEqual(json, "{\n  \"name\": \"say \\\"hi\\\"\"\n}")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    func testRepeaterReadings() {
        var r = RepeaterReadings.practice
        XCTAssertEqual(r.airtimePercent ?? 0, Double(r.airtime) / Double(r.uptime) * 100, accuracy: 0.001)
        XCTAssertTrue(r.summary.hasPrefix("Healthy"))
        r.batteryMillivolts = 3350
        XCTAssertTrue(r.summary.hasPrefix("Battery low"))
        r.uptime = 0
        XCTAssertNil(r.airtimePercent)
    }

    func testPracticeTraceGoesOutAndBack() {
        let c = contact(0x3e, .room, hops: 1, path: [0x1c])
        let tr = TraceReading.practice(c)
        XCTAssertEqual(tr.hops.map(\.hash), [Data([0x1c]), Data([0x3e]), Data([0x1c])])
        XCTAssertEqual(tr.weakest, -3.25)
    }

    @MainActor func testAdvertSignalIgnoresGarbage() {
        XCTAssertNil(PacketFeed.advertSignal(Data([0x11]), snr: 3, rssi: -90))
        XCTAssertNil(PacketFeed.advertSignal(Data([0x11, 0x00]), snr: .nan, rssi: -90))
    }

    @MainActor func testPracticeSignalFallsWithHops() {
        let near = PacketFeed.practiceSignal(contact(0x1c, .repeater, hops: 0))
        let far = PacketFeed.practiceSignal(contact(0x1c, .chat, hops: 2))
        XCTAssertGreaterThan(near.snr, far.snr)
        XCTAssertEqual(far.hops, 2)
    }
}
